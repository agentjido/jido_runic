defmodule JidoRunicTest.ActionNodeTest do
  use ExUnit.Case, async: true

  alias JidoRunic.ActionNode
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  alias JidoRunicTest.TestActions.{AddOne, Double, Concat, FailingAction, NoSchemaAction}

  describe "new/3" do
    test "creates an ActionNode with default name from module" do
      node = ActionNode.new(AddOne)
      assert node.name == :add_one
      assert node.action_mod == AddOne
      assert node.params == %{}
      assert is_integer(node.hash)
    end

    test "creates an ActionNode with custom name" do
      node = ActionNode.new(AddOne, %{}, name: :increment)
      assert node.name == :increment
    end

    test "creates an ActionNode with default params" do
      node = ActionNode.new(AddOne, %{value: 5})
      assert node.params == %{value: 5}
    end

    test "derives inputs from action schema" do
      node = ActionNode.new(AddOne)
      assert Keyword.has_key?(node.inputs, :value)
    end

    test "handles actions without schema" do
      node = ActionNode.new(NoSchemaAction)
      assert node.inputs == [input: [type: :any, doc: "Input to the action"]]
    end

    test "produces stable hashes for same inputs" do
      node1 = ActionNode.new(AddOne, %{value: 5}, name: :test)
      node2 = ActionNode.new(AddOne, %{value: 5}, name: :test)
      assert node1.hash == node2.hash
    end

    test "produces different hashes for different params" do
      node1 = ActionNode.new(AddOne, %{value: 5}, name: :test)
      node2 = ActionNode.new(AddOne, %{value: 10}, name: :test)
      assert node1.hash != node2.hash
    end
  end

  describe "workflow integration" do
    test "ActionNode can be added to a workflow" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:test_workflow) |> Workflow.add(node)

      component = Workflow.get_component(workflow, :add)
      assert component.name == :add
    end

    test "single ActionNode workflow produces correct result" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:test_workflow) |> Workflow.add(node)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 6} in result
    end

    test "chained ActionNodes produce correct result" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      double = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:chain)
        |> Workflow.add(add)
        |> Workflow.add(double, to: :add)

      results =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 6} in results
      assert %{value: 12} in results
    end

    test "ActionNode with default params merges with input" do
      node = ActionNode.new(Concat, %{b: " world"}, name: :greet)
      workflow = Workflow.new(:merge_test) |> Workflow.add(node)

      results =
        workflow
        |> Workflow.react_until_satisfied(%{a: "hello"})
        |> Workflow.raw_productions()

      assert %{result: "hello world"} in results
    end

    test "failed action produces no downstream facts" do
      fail_node = ActionNode.new(FailingAction, %{}, name: :fail)
      add_node = ActionNode.new(AddOne, %{}, name: :add)

      workflow =
        Workflow.new(:fail_test)
        |> Workflow.add(fail_node)
        |> Workflow.add(add_node, to: :fail)

      results =
        workflow
        |> Workflow.react_until_satisfied(%{})
        |> Workflow.raw_productions()

      refute Enum.any?(results, fn r -> is_map(r) and Map.has_key?(r, :value) end)
    end
  end

  describe "three-phase execution" do
    test "prepare returns a runnable" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      fact = Fact.new(value: %{value: 5}, ancestry: nil)
      workflow = Workflow.new(:test) |> Workflow.add(node)

      assert {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      assert runnable.node == node
      assert runnable.input_fact == fact
      assert runnable.status == :pending
    end

    test "execute completes runnable with result" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      fact = Fact.new(value: %{value: 5}, ancestry: nil)
      workflow = Workflow.new(:test) |> Workflow.add(node)

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      assert executed.status == :completed
      assert executed.result.value == %{value: 6}
      assert is_function(executed.apply_fn, 1)
    end

    test "execute fails runnable on action error" do
      node = ActionNode.new(FailingAction, %{}, name: :fail)
      fact = Fact.new(value: %{}, ancestry: nil)
      workflow = Workflow.new(:test) |> Workflow.add(node)

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      assert executed.status == :failed
      assert executed.error != nil
    end

    test "apply_fn reduces result back into workflow" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      fact = Fact.new(value: %{value: 5}, ancestry: nil)
      workflow = Workflow.new(:test) |> Workflow.add(node)

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      updated_workflow = executed.apply_fn.(workflow)
      assert is_struct(updated_workflow, Workflow)
    end
  end

  describe "provenance" do
    test "result fact has correct ancestry" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      fact = Fact.new(value: %{value: 5}, ancestry: nil)
      workflow = Workflow.new(:test) |> Workflow.add(node)

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      result_fact = executed.result
      {producer_hash, parent_hash} = result_fact.ancestry
      assert producer_hash == node.hash
      assert parent_hash == fact.hash
    end
  end

  describe "Component protocol" do
    test "hash returns node hash" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      assert Runic.Component.hash(node) == node.hash
    end

    test "inputs returns derived schema" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      inputs = Runic.Component.inputs(node)
      assert Keyword.has_key?(inputs, :value)
    end

    test "source returns reconstructable AST" do
      node = ActionNode.new(AddOne, %{value: 5}, name: :add)
      source = Runic.Component.source(node)
      assert is_tuple(source)
    end
  end

  describe "Transmutable protocol" do
    test "to_workflow wraps node in a workflow" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Runic.Transmutable.to_workflow(node)
      assert is_struct(workflow, Workflow)
    end

    test "to_component returns node itself" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      assert Runic.Transmutable.to_component(node) == node
    end
  end
end
