defmodule JidoRunicTest.IntrospectionTest do
  use ExUnit.Case, async: true

  alias JidoRunic.Introspection
  alias JidoRunic.ActionNode
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  alias JidoRunicTest.TestActions.{AddOne, Double}

  describe "provenance_chain/2" do
    test "traces a single-node workflow back to root" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:single) |> Workflow.add(node)

      workflow = Workflow.react_until_satisfied(workflow, %{value: 5})

      leaf_fact =
        workflow
        |> Workflow.facts()
        |> Enum.find(fn f -> f.value == %{value: 6} end)

      assert {:ok, chain} = Introspection.provenance_chain(workflow, leaf_fact.hash)
      assert length(chain) == 2

      [{root_fact, nil}, {produced_fact, producer_hash}] = chain
      assert root_fact.value == %{value: 5}
      assert root_fact.ancestry == nil
      assert produced_fact.value == %{value: 6}
      assert producer_hash == node.hash
    end

    test "traces a chained workflow (AddOne -> Double) back to root" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      double = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:chain)
        |> Workflow.add(add)
        |> Workflow.add(double, to: :add)

      workflow = Workflow.react_until_satisfied(workflow, %{value: 5})

      leaf_fact =
        workflow
        |> Workflow.facts()
        |> Enum.find(fn f -> f.value == %{value: 12} end)

      assert {:ok, chain} = Introspection.provenance_chain(workflow, leaf_fact.hash)
      assert length(chain) == 3

      [{root, nil}, {mid, add_hash}, {leaf, dbl_hash}] = chain
      assert root.value == %{value: 5}
      assert mid.value == %{value: 6}
      assert leaf.value == %{value: 12}
      assert add_hash == add.hash
      assert dbl_hash == double.hash
    end

    test "returns error when fact_hash is not found" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:missing) |> Workflow.add(node)
      workflow = Workflow.react_until_satisfied(workflow, %{value: 1})

      assert {:error, :fact_not_found} = Introspection.provenance_chain(workflow, 999_999)
    end

    test "works with a map containing :facts key (Studio pipeline result)" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:studio) |> Workflow.add(add)
      workflow = Workflow.react_until_satisfied(workflow, %{value: 10})

      facts = Workflow.facts(workflow)
      leaf_fact = Enum.find(facts, fn f -> f.value == %{value: 11} end)

      result_map = %{facts: facts}
      assert {:ok, chain} = Introspection.provenance_chain(result_map, leaf_fact.hash)
      assert length(chain) == 2

      [{root, nil}, {produced, _producer}] = chain
      assert root.value == %{value: 10}
      assert produced.value == %{value: 11}
    end
  end

  describe "execution_summary/1" do
    test "returns correct counts for a satisfied workflow" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      double = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:summary)
        |> Workflow.add(add)
        |> Workflow.add(double, to: :add)

      workflow = Workflow.react_until_satisfied(workflow, %{value: 5})

      summary = Introspection.execution_summary(workflow)

      assert summary.total_nodes == 2
      assert summary.facts_produced >= 3
      assert summary.satisfied == true
      assert summary.productions >= 2
    end

    test "returns satisfied false for a workflow with pending runnables" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:pending) |> Workflow.add(add)

      fact = Fact.new(value: %{value: 1}, ancestry: nil)
      workflow = Workflow.plan_eagerly(workflow, fact)

      summary = Introspection.execution_summary(workflow)

      assert summary.satisfied == false
    end
  end
end
