defmodule Jido.RunicTest.Introspection do
  use ExUnit.Case, async: true

  alias Jido.Runic.ActionNode
  alias Jido.Runic.Introspection
  alias Jido.RunicTest.Actions.{Add, Double}
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  defp pipeline_workflow do
    add_node = ActionNode.new(Add, %{amount: 1}, name: :add)
    double_node = ActionNode.new(Double, %{}, name: :double)

    Workflow.new(name: :pipeline)
    |> Workflow.add(add_node)
    |> Workflow.add(double_node, to: :add)
  end

  defp run_pipeline(input \\ %{value: 5}) do
    pipeline_workflow()
    |> Workflow.react_until_satisfied(input)
  end

  defp single_workflow do
    node = ActionNode.new(Add, %{amount: 10}, name: :add)

    Workflow.new(name: :single)
    |> Workflow.add(node)
  end

  describe "provenance_chain/2" do
    test "returns {:error, :fact_not_found} for unknown hash" do
      wf = run_pipeline()
      assert {:error, :fact_not_found} = Introspection.provenance_chain(wf, 0)
    end

    test "returns chain for a single root fact" do
      wf = run_pipeline()
      root_fact = Workflow.facts(wf) |> Enum.find(&(&1.ancestry == nil))

      assert {:ok, chain} = Introspection.provenance_chain(wf, root_fact.hash)
      assert [{^root_fact, nil}] = chain
    end

    test "returns full chain through a pipeline" do
      wf = run_pipeline()
      facts = Workflow.facts(wf)
      produced = Enum.find(facts, &(&1.ancestry != nil))

      if produced do
        assert {:ok, chain} = Introspection.provenance_chain(wf, produced.hash)
        assert length(chain) >= 2

        {root, nil} = List.first(chain)
        assert root.ancestry == nil

        {tail_fact, producer_hash} = List.last(chain)
        assert tail_fact.hash == produced.hash
        assert is_integer(producer_hash)
      end
    end

    test "accepts %{facts: [...]} map as source" do
      wf = run_pipeline()
      facts = Workflow.facts(wf)
      root_fact = Enum.find(facts, &(&1.ancestry == nil))

      assert {:ok, chain} = Introspection.provenance_chain(%{facts: facts}, root_fact.hash)
      assert [{^root_fact, nil}] = chain
    end

    test "handles partial chain when parent hash not in index" do
      producer_hash = 111
      missing_parent_hash = 999

      root = Fact.new(value: %{x: 1})

      child =
        Fact.new(value: %{x: 2}, ancestry: {producer_hash, missing_parent_hash})

      assert {:ok, chain} = Introspection.provenance_chain(%{facts: [root, child]}, child.hash)
      assert [{^child, ^producer_hash}] = chain
    end
  end

  describe "execution_summary/1" do
    test "returns correct counts for a fresh workflow" do
      wf = pipeline_workflow()
      summary = Introspection.execution_summary(wf)

      assert summary.total_nodes == 2
      assert summary.facts_produced == 0
      assert summary.productions == 0
    end

    test "returns correct counts after running a workflow" do
      wf = run_pipeline()
      summary = Introspection.execution_summary(wf)

      assert summary.total_nodes == 2
      assert summary.facts_produced >= 1
      assert is_boolean(summary.satisfied)
    end
  end

  describe "step_report/1" do
    test "reports :completed for hashes in ran_nodes" do
      hash = 123

      strat = %{
        ran_nodes: MapSet.new([hash]),
        pending: %{},
        queued: []
      }

      report = Introspection.step_report(strat)
      entry = Enum.find(report, &(&1.hash == hash))
      assert entry.status == :completed
      assert entry.pending_since == nil
    end

    test "reports :pending for hashes in pending map" do
      hash = 456
      runnable = %{node: %{hash: hash}}

      strat = %{
        ran_nodes: MapSet.new(),
        pending: %{"id1" => runnable},
        queued: []
      }

      report = Introspection.step_report(strat)
      entry = Enum.find(report, &(&1.hash == hash))
      assert entry.status == :pending
      assert entry.pending_since == runnable
    end

    test "reports :queued for hashes in queued list" do
      hash = 789
      runnable = %{node: %{hash: hash}}

      strat = %{
        ran_nodes: MapSet.new(),
        pending: %{},
        queued: [runnable]
      }

      report = Introspection.step_report(strat)
      entry = Enum.find(report, &(&1.hash == hash))
      assert entry.status == :queued
      assert entry.pending_since == nil
    end

    test "handles empty state gracefully" do
      strat = %{ran_nodes: MapSet.new(), pending: %{}, queued: []}
      assert Introspection.step_report(strat) == []
    end
  end

  describe "node_map/1" do
    test "returns action_mod for ActionNode" do
      wf = single_workflow()
      map = Introspection.node_map(wf)

      assert map_size(map) == 1
      info = map[:add]
      assert info.type == :action_node
      assert info.action_mod == Add
      assert is_integer(info.hash)
    end

    test "returns nil action_mod for non-ActionNode" do
      step = Runic.Transmutable.to_component(fn x -> x end)

      wf =
        Workflow.new(name: :step_test)
        |> Workflow.add(step)

      map = Introspection.node_map(wf)
      [{_name, info}] = Map.to_list(map)
      assert info.type == :step
      assert info.action_mod == nil
    end
  end

  describe "workflow_graph/1" do
    test "returns nodes and edges for a pipeline workflow" do
      wf = pipeline_workflow()
      graph = Introspection.workflow_graph(wf)

      assert length(graph.nodes) == 2
      node_names = Enum.map(graph.nodes, & &1.name)
      assert :add in node_names
      assert :double in node_names
      assert Enum.all?(graph.nodes, &Map.has_key?(&1, :executor))
      assert Enum.any?(graph.nodes, &(&1.action_mod == Add))

      assert length(graph.edges) >= 1
      edge = hd(graph.edges)
      assert Map.has_key?(edge, :from)
      assert Map.has_key?(edge, :to)
      assert Map.has_key?(edge, :label)
    end

    test "filters out self-loops" do
      wf = pipeline_workflow()
      graph = Introspection.workflow_graph(wf)

      Enum.each(graph.edges, fn edge ->
        assert edge.from != edge.to
      end)
    end

    test "deduplicates edges" do
      wf = pipeline_workflow()
      graph = Introspection.workflow_graph(wf)

      assert graph.edges == Enum.uniq(graph.edges)
    end
  end

  describe "annotated_graph/2" do
    test "all nodes :idle when no execution has happened" do
      wf = pipeline_workflow()
      strat = %{ran_nodes: MapSet.new(), pending: %{}, status: :idle}
      graph = Introspection.annotated_graph(wf, strat)

      Enum.each(graph.nodes, fn node ->
        assert node.status == :idle
      end)
    end

    test "shows :completed for ran nodes" do
      wf = pipeline_workflow()
      add_hash = Introspection.node_map(wf)[:add].hash

      strat = %{ran_nodes: MapSet.new([add_hash]), pending: %{}, status: :idle}
      graph = Introspection.annotated_graph(wf, strat)

      add_node = Enum.find(graph.nodes, &(&1.name == :add))
      double_node = Enum.find(graph.nodes, &(&1.name == :double))

      assert add_node.status == :completed
      assert double_node.status == :idle
    end

    test "shows :pending for pending nodes" do
      wf = pipeline_workflow()
      double_hash = Introspection.node_map(wf)[:double].hash
      runnable = %{node: %{hash: double_hash}}

      strat = %{ran_nodes: MapSet.new(), pending: %{"r1" => runnable}, status: :idle}
      graph = Introspection.annotated_graph(wf, strat)

      double_node = Enum.find(graph.nodes, &(&1.name == :double))
      assert double_node.status == :pending
    end

    test "shows :failed when strategy status is :failure" do
      wf = pipeline_workflow()
      strat = %{ran_nodes: MapSet.new(), pending: %{}, status: :failure}
      graph = Introspection.annotated_graph(wf, strat)

      Enum.each(graph.nodes, fn node ->
        assert node.status == :failed
      end)
    end

    test "shows :waiting when strategy status is :waiting" do
      wf = pipeline_workflow()
      strat = %{ran_nodes: MapSet.new(), pending: %{}, status: :waiting}
      graph = Introspection.annotated_graph(wf, strat)

      Enum.each(graph.nodes, fn node ->
        assert node.status == :waiting
      end)
    end
  end

  describe "node_map/1 edge cases" do
    test "returns nil hash for a struct without hash field" do
      plain = %{__struct__: SomeUnknown, name: :plain}
      %Workflow{} = base = Workflow.new(name: :edge)
      wf = %{base | components: %{plain: plain}}

      map = Introspection.node_map(wf)
      assert map[:plain].hash == nil
      assert map[:plain].type == :unknown
    end

    test "returns empty inputs for a node with nil inputs" do
      node = %{__struct__: SomeUnknown, name: :no_inputs, hash: 42, inputs: nil, outputs: nil}
      %Workflow{} = base = Workflow.new(name: :edge)
      wf = %{base | components: %{no_inputs: node}}

      map = Introspection.node_map(wf)
      assert map[:no_inputs].inputs == []
      assert map[:no_inputs].outputs == []
    end

    test "returns empty inputs for a node without inputs field" do
      node = %{__struct__: SomeUnknown, name: :bare, hash: 99}
      %Workflow{} = base = Workflow.new(name: :edge)
      wf = %{base | components: %{bare: node}}

      map = Introspection.node_map(wf)
      assert map[:bare].inputs == []
      assert map[:bare].outputs == []
    end
  end
end
