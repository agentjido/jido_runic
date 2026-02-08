defmodule Jido.Runic.ActionNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.ActionNode
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  alias Jido.RunicTest.Actions.{Add, Double, Fail, NoSchema}

  describe "new/3" do
    test "creates an ActionNode with default name derived from module" do
      node = ActionNode.new(Add)
      assert node.name == :add
      assert node.action_mod == Add
      assert node.params == %{}
      assert is_integer(node.hash)
    end

    test "accepts custom name" do
      node = ActionNode.new(Add, %{}, name: :my_adder)
      assert node.name == :my_adder
    end

    test "accepts params" do
      node = ActionNode.new(Add, %{amount: 5})
      assert node.params == %{amount: 5}
    end

    test "different params produce different hashes" do
      node1 = ActionNode.new(Add, %{amount: 1})
      node2 = ActionNode.new(Add, %{amount: 2})
      assert node1.hash != node2.hash
    end

    test "same params produce same hash" do
      node1 = ActionNode.new(Add, %{amount: 1}, name: :add)
      node2 = ActionNode.new(Add, %{amount: 1}, name: :add)
      assert node1.hash == node2.hash
    end

    test "derives inputs from action schema" do
      node = ActionNode.new(Add)
      input_keys = Keyword.keys(node.inputs)
      assert :value in input_keys
      assert :amount in input_keys
    end

    test "uses default inputs for schemaless actions" do
      node = ActionNode.new(NoSchema)
      assert node.inputs == [input: [type: :any, doc: "Input to the action"]]
    end

    test "defaults exec timeout to 0 (inline execution)" do
      node = ActionNode.new(Add)
      assert Keyword.get(node.exec_opts, :timeout) == 0
    end

    test "allows overriding exec timeout" do
      node = ActionNode.new(Add, %{}, timeout: 5000)
      assert Keyword.get(node.exec_opts, :timeout) == 5000
    end
  end

  describe "action_metadata/1" do
    test "returns action metadata" do
      node = ActionNode.new(Add)
      metadata = ActionNode.action_metadata(node)
      assert metadata.name == "add"
      assert metadata.description == "Adds a value to the input"
    end
  end

  describe "single-node workflow execution" do
    test "executes action and produces result fact" do
      node = ActionNode.new(Add, %{amount: 10}, name: :add)

      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(node)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 15} in result
    end

    test "executes action with default params" do
      node = ActionNode.new(Add, %{}, name: :add)

      result =
        Workflow.new(name: :test)
        |> Workflow.add(node)
        |> Workflow.react_until_satisfied(%{value: 10, amount: 3})
        |> Workflow.raw_productions()

      assert %{value: 13} in result
    end

    test "handles action failure gracefully" do
      node = ActionNode.new(Fail, %{}, name: :fail)

      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(node)
        |> Workflow.react_until_satisfied(%{reason: "boom"})

      productions = Workflow.raw_productions(workflow)
      assert productions == []
    end
  end

  describe "multi-node workflow (pipeline)" do
    test "chains two actions sequentially" do
      add_node = ActionNode.new(Add, %{amount: 1}, name: :add)
      double_node = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(name: :pipeline)
        |> Workflow.add(add_node)
        |> Workflow.add(double_node, to: :add)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 12} in result
    end
  end

  describe "Runic.Component protocol" do
    test "hash returns the node's hash" do
      node = ActionNode.new(Add)
      assert Runic.Component.hash(node) == node.hash
    end

    test "inputs returns the derived schema" do
      node = ActionNode.new(Add)
      inputs = Runic.Component.inputs(node)
      assert Keyword.has_key?(inputs, :value)
    end

    test "outputs returns default schema" do
      node = ActionNode.new(Add)
      outputs = Runic.Component.outputs(node)
      assert Keyword.has_key?(outputs, :result)
    end

    test "connectable? returns true" do
      node = ActionNode.new(Add)
      assert Runic.Component.connectable?(node, nil)
    end

    test "source returns reconstructable AST" do
      node = ActionNode.new(Add, %{amount: 5}, name: :add)
      ast = Runic.Component.source(node)
      assert is_tuple(ast)
    end
  end

  describe "Runic.Transmutable protocol" do
    test "to_workflow wraps node in a workflow" do
      node = ActionNode.new(Add, %{}, name: :add)
      workflow = Runic.Transmutable.to_workflow(node)
      assert %Workflow{} = workflow
    end

    test "to_component returns the node itself" do
      node = ActionNode.new(Add)
      assert Runic.Transmutable.to_component(node) == node
    end
  end

  describe "three-phase execution (prepare/execute/apply)" do
    test "prepare returns a pending runnable" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add)

      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(node)

      fact = Fact.new(value: %{value: 5})

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      assert runnable.status == :pending
      assert runnable.node == node
      assert runnable.input_fact == fact
    end

    test "execute produces a completed runnable on success" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add)

      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(node)

      fact = Fact.new(value: %{value: 5})

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      assert executed.status == :completed
      assert %Fact{value: %{value: 6}} = executed.result
    end

    test "execute produces a failed runnable on error" do
      node = ActionNode.new(Fail, %{}, name: :fail)

      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(node)

      fact = Fact.new(value: %{reason: "test error"})

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      assert executed.status == :failed
      assert executed.error != nil
    end

    test "apply_fn reduces result back into workflow" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add)

      workflow =
        Workflow.new(name: :test)
        |> Workflow.add(node)

      fact = Fact.new(value: %{value: 5})

      {:ok, runnable} = Runic.Workflow.Invokable.prepare(node, workflow, fact)
      executed = Runic.Workflow.Invokable.execute(node, runnable)

      assert executed.status == :completed
      updated_workflow = executed.apply_fn.(workflow)
      assert %Workflow{} = updated_workflow
    end
  end
end
