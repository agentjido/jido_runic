defmodule Jido.Runic.Introspection do
  @moduledoc """
  Provenance queries, workflow execution summaries, and graph introspection.

  Provides utilities to trace how facts were produced through a workflow,
  generate summary statistics about execution state, inspect strategy
  step history, and produce structured graph representations for UI rendering.
  """

  alias Runic.Workflow
  alias Runic.Workflow.Fact

  @type fact_source :: %Workflow{} | %{facts: [Fact.t()]}
  @type provenance_entry :: {Fact.t(), integer() | nil}

  @type node_info :: %{
          hash: integer(),
          inputs: keyword(),
          outputs: keyword(),
          type: atom(),
          action_mod: module() | nil
        }

  @type graph_node :: %{
          name: atom(),
          hash: integer(),
          type: atom()
        }

  @type graph_edge :: %{
          from: integer(),
          to: integer(),
          label: atom()
        }

  @type node_status :: :pending | :completed | :failed | :waiting | :idle

  @doc """
  Walk Fact ancestry back through the workflow's facts.

  Returns a list of `{fact, producing_node_hash_or_nil}` tuples ordered
  from the root input fact to the target fact identified by `fact_hash`.

  Accepts either a `%Runic.Workflow{}` or a map with a `:facts` key.

  Returns `{:ok, chain}` on success, or `{:error, :fact_not_found}` if the
  target fact is not found.
  """
  @spec provenance_chain(fact_source(), Fact.hash()) ::
          {:ok, [provenance_entry()]} | {:error, :fact_not_found}
  def provenance_chain(source, fact_hash) do
    facts = extract_facts(source)
    index = Map.new(facts, fn fact -> {fact.hash, fact} end)

    case Map.get(index, fact_hash) do
      nil -> {:error, :fact_not_found}
      target -> {:ok, build_chain(target, index, [])}
    end
  end

  @doc """
  Return a summary map with execution statistics for the given workflow.

  Keys returned:

    * `:total_nodes` — count of registered components
    * `:facts_produced` — count of facts in the workflow
    * `:satisfied` — `true` when the workflow has no remaining runnables
    * `:productions` — count of raw production values
  """
  @spec execution_summary(Workflow.t()) :: %{
          total_nodes: non_neg_integer(),
          facts_produced: non_neg_integer(),
          satisfied: boolean(),
          productions: non_neg_integer()
        }
  def execution_summary(%Workflow{} = workflow) do
    %{
      total_nodes: workflow |> Workflow.components() |> map_size(),
      facts_produced: workflow |> Workflow.facts() |> length(),
      satisfied: not Workflow.is_runnable?(workflow),
      productions: workflow |> Workflow.raw_productions() |> length()
    }
  end

  @doc """
  Produce a report from strategy state step history.

  Takes a strategy state map (as returned by `StratState.get(agent)`) and
  returns a list of step report maps with enriched info about each tracked node.

  Each map contains:

    * `:hash` — the node hash
    * `:status` — `:completed` if in `ran_nodes`, `:pending` if in `pending`, `:queued` otherwise
    * `:pending_since` — runnable struct if currently pending, `nil` otherwise
  """
  @spec step_report(map()) :: [map()]
  def step_report(strat_state) when is_map(strat_state) do
    ran_nodes = Map.get(strat_state, :ran_nodes, MapSet.new())
    pending = Map.get(strat_state, :pending, %{})
    queued = Map.get(strat_state, :queued, [])

    pending_hashes =
      pending
      |> Map.values()
      |> Map.new(fn runnable -> {runnable.node.hash, runnable} end)

    queued_hashes =
      queued
      |> Map.new(fn runnable -> {runnable.node.hash, runnable} end)

    all_hashes =
      MapSet.union(ran_nodes, MapSet.new(Map.keys(pending_hashes)))
      |> MapSet.union(MapSet.new(Map.keys(queued_hashes)))

    Enum.map(all_hashes, fn hash ->
      cond do
        MapSet.member?(ran_nodes, hash) ->
          %{hash: hash, status: :completed, pending_since: nil}

        Map.has_key?(pending_hashes, hash) ->
          %{hash: hash, status: :pending, pending_since: Map.get(pending_hashes, hash)}

        Map.has_key?(queued_hashes, hash) ->
          %{hash: hash, status: :queued, pending_since: nil}
      end
    end)
  end

  @doc """
  Return a map of all registered components in a workflow.

  Returns `%{node_name => node_info}` where `node_info` includes `:hash`,
  `:inputs`, `:outputs`, `:type`, and `:action_mod` (for `Jido.Runic.ActionNode`).
  """
  @spec node_map(Workflow.t()) :: %{atom() => node_info()}
  def node_map(%Workflow{} = workflow) do
    workflow
    |> Workflow.components()
    |> Map.new(fn {name, node} ->
      {name, build_node_info(node)}
    end)
  end

  @doc """
  Return a structured graph representation of workflow nodes and edges.

  Returns `%{nodes: [...], edges: [...]}` where each node has `:name`, `:hash`,
  `:type` and each edge has `:from`, `:to`, `:label`.

  Only includes structural edges (excludes runtime fact edges like `:produced`,
  `:ran`, etc.) to represent the static workflow topology.
  """
  @spec workflow_graph(Workflow.t()) :: %{nodes: [graph_node()], edges: [graph_edge()]}
  def workflow_graph(%Workflow{} = workflow) do
    components = Workflow.components(workflow)

    nodes =
      Enum.map(components, fn {name, node} ->
        %{name: name, hash: node_hash(node), type: node_type(node)}
      end)

    component_hashes = MapSet.new(nodes, & &1.hash)

    edges =
      workflow.graph
      |> Graph.edges()
      |> Enum.filter(fn edge ->
        from_hash = node_hash(edge.v1)
        to_hash = node_hash(edge.v2)
        from_hash != nil and to_hash != nil and
          MapSet.member?(component_hashes, from_hash) and
          MapSet.member?(component_hashes, to_hash) and
          from_hash != to_hash
      end)
      |> Enum.map(fn edge ->
        %{from: node_hash(edge.v1), to: node_hash(edge.v2), label: edge.label}
      end)
      |> Enum.uniq()

    %{nodes: nodes, edges: edges}
  end

  @doc """
  Return the workflow graph annotated with execution status per node.

  Combines the static workflow graph with strategy state to annotate each node
  with its current execution status:

    * `:completed` — node hash is in `ran_nodes`
    * `:pending` — node hash is in `pending` (currently executing)
    * `:failed` — strategy status is `:failure` and node was not completed
    * `:waiting` — strategy status is `:waiting`
    * `:idle` — no execution activity for this node
  """
  @spec annotated_graph(Workflow.t(), map()) :: %{nodes: [map()], edges: [graph_edge()]}
  def annotated_graph(%Workflow{} = workflow, strat_state) when is_map(strat_state) do
    %{nodes: nodes, edges: edges} = workflow_graph(workflow)

    ran_nodes = Map.get(strat_state, :ran_nodes, MapSet.new())
    pending = Map.get(strat_state, :pending, %{})
    strategy_status = Map.get(strat_state, :status, :idle)

    pending_hashes =
      pending
      |> Map.values()
      |> MapSet.new(fn runnable -> runnable.node.hash end)

    annotated_nodes =
      Enum.map(nodes, fn node ->
        status =
          cond do
            MapSet.member?(ran_nodes, node.hash) -> :completed
            MapSet.member?(pending_hashes, node.hash) -> :pending
            strategy_status == :failure -> :failed
            strategy_status == :waiting -> :waiting
            true -> :idle
          end

        Map.put(node, :status, status)
      end)

    %{nodes: annotated_nodes, edges: edges}
  end

  # -- Private -----------------------------------------------------------------

  defp build_chain(%Fact{ancestry: nil} = fact, _index, acc) do
    [{fact, nil} | acc]
  end

  defp build_chain(%Fact{ancestry: {producer_hash, parent_hash}} = fact, index, acc) do
    acc = [{fact, producer_hash} | acc]

    case Map.get(index, parent_hash) do
      nil -> acc
      parent -> build_chain(parent, index, acc)
    end
  end

  defp extract_facts(%Workflow{} = workflow), do: Workflow.facts(workflow)
  defp extract_facts(%{facts: facts}) when is_list(facts), do: facts

  defp build_node_info(node) do
    base = %{
      hash: node_hash(node),
      inputs: node_inputs(node),
      outputs: node_outputs(node),
      type: node_type(node)
    }

    if match?(%Jido.Runic.ActionNode{}, node) do
      Map.put(base, :action_mod, node.action_mod)
    else
      Map.put(base, :action_mod, nil)
    end
  end

  defp node_hash(%{hash: hash}), do: hash
  defp node_hash(_), do: nil

  defp node_inputs(%{inputs: inputs}) when not is_nil(inputs), do: inputs
  defp node_inputs(_), do: []

  defp node_outputs(%{outputs: outputs}) when not is_nil(outputs), do: outputs
  defp node_outputs(_), do: []

  defp node_type(%Jido.Runic.ActionNode{}), do: :action_node
  defp node_type(%Runic.Workflow.Step{}), do: :step
  defp node_type(%Runic.Workflow.Rule{}), do: :rule
  defp node_type(%Runic.Workflow.Condition{}), do: :condition
  defp node_type(%Runic.Workflow.Join{}), do: :join
  defp node_type(%Runic.Workflow.FanOut{}), do: :fan_out
  defp node_type(%Runic.Workflow.FanIn{}), do: :fan_in
  defp node_type(%Runic.Workflow.Accumulator{}), do: :accumulator
  defp node_type(%Runic.Workflow.StateMachine{}), do: :state_machine
  defp node_type(_), do: :unknown
end
