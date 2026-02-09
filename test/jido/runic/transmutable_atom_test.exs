defmodule Jido.Runic.TransmutableAtomTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.ActionNode
  alias Runic.Workflow

  alias Jido.RunicTest.Actions.{Add, Double, Fail}

  describe "to_component/1" do
    test "transmutes a Jido Action module into an ActionNode" do
      node = Runic.Transmutable.to_component(Add)
      assert %ActionNode{} = node
      assert node.action_mod == Add
      assert node.name == :add
    end

    test "preserves schema introspection" do
      node = Runic.Transmutable.to_component(Add)
      input_keys = Keyword.keys(node.inputs)
      assert :value in input_keys
      assert :amount in input_keys
    end

    test "falls back to default behavior for non-action atoms" do
      step = Runic.Transmutable.to_component(:some_value)
      assert %Runic.Workflow.Step{} = step
    end
  end

  describe "to_workflow/1" do
    test "transmutes a Jido Action module into a Workflow" do
      workflow = Runic.Transmutable.to_workflow(Add)
      assert %Workflow{} = workflow
    end

    test "falls back to default behavior for non-action atoms" do
      workflow = Runic.Transmutable.to_workflow(:some_value)
      assert %Workflow{} = workflow
    end
  end

  describe "Workflow.add/3 with action modules" do
    test "adds a single action module to a workflow" do
      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(Add)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5, amount: 10})
        |> Workflow.raw_productions()

      assert %{value: 15} in result
    end

    test "chains action modules in a pipeline" do
      workflow =
        Workflow.new(name: :pipeline)
        |> Workflow.add(Add)
        |> Workflow.add(Double, to: :add)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5, amount: 1})
        |> Workflow.raw_productions()

      assert %{value: 12} in result
    end

    test "handles failing action modules" do
      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(Fail)
        |> Workflow.react_until_satisfied(%{reason: "boom"})

      productions = Workflow.raw_productions(workflow)
      assert productions == []
    end

    test "mixes action modules with ActionNode structs" do
      double_node = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(name: :mixed)
        |> Workflow.add(Add)
        |> Workflow.add(double_node, to: :add)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5, amount: 1})
        |> Workflow.raw_productions()

      assert %{value: 12} in result
    end
  end
end
