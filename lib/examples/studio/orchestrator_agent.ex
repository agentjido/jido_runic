defmodule JidoRunic.Examples.Studio.OrchestratorAgent do
  @moduledoc """
  Orchestrator agent for the AI Research Studio.

  Provides a single `run/2` entrypoint that starts an AgentServer, feeds a topic
  into the Runic workflow, and waits for completion via `await_completion`.

  The workflow DAG is passed to the strategy via
  `strategy: {JidoRunic.Strategy, workflow: build_workflow()}` — the strategy
  receives it in `init/2` so no `set_workflow` signal is needed at runtime.
  """
  use Jido.Agent,
    name: "studio_orchestrator",
    strategy: {JidoRunic.Strategy, workflow_fn: &__MODULE__.build_workflow/0},
    schema: []

  alias JidoRunic.ActionNode
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias JidoRunic.Examples.Studio.Actions
  alias JidoRunic.Examples.Studio.BatchActions

  @doc """
  Build the Runic DAG for the research pipeline.

  Pipeline: PlanQueries → WebSearchBatch → ExtractClaimsBatch → BuildOutline → DraftSectionsBatch → EditAndAssemble
  """
  def build_workflow do
    plan = ActionNode.new(Actions.PlanQueries, %{}, name: :plan_queries)
    search = ActionNode.new(BatchActions.WebSearchBatch, %{}, name: :web_search_batch)
    extract = ActionNode.new(BatchActions.ExtractClaimsBatch, %{}, name: :extract_claims_batch)
    outline = ActionNode.new(Actions.BuildOutline, %{}, name: :build_outline)
    draft = ActionNode.new(BatchActions.DraftSectionsBatch, %{}, name: :draft_sections_batch)
    edit = ActionNode.new(Actions.EditAndAssemble, %{}, name: :edit_and_assemble)

    Workflow.new(:research_studio)
    |> Workflow.add(plan)
    |> Workflow.add(search, to: :plan_queries)
    |> Workflow.add(extract, to: :web_search_batch)
    |> Workflow.add(outline, to: :extract_claims_batch)
    |> Workflow.add(draft, to: :build_outline)
    |> Workflow.add(edit, to: :draft_sections_batch)
  end

  @doc """
  Run the full research pipeline for a topic through the AgentServer.

  ## Options

    * `:jido` - Name of an existing Jido instance (starts a temporary one if omitted)
    * `:timeout` - Timeout in ms for `await_completion` (default: 30_000)
    * `:debug` - Enable debug event buffer (default: true)

  ## Returns

  A map with `:topic`, `:productions`, `:facts`, `:status`, `:events`, and `:pid`.
  """
  @spec run(String.t(), keyword()) :: map()
  def run(topic, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    debug = Keyword.get(opts, :debug, true)

    {jido, jido_started?} =
      case Keyword.get(opts, :jido) do
        nil ->
          name = :"jido_studio_#{System.unique_integer([:positive])}"
          {:ok, _} = Jido.start_link(name: name)
          {name, true}

        name ->
          {name, false}
      end

    server_opts = [agent: __MODULE__, jido: jido, debug: debug]
    {:ok, pid} = Jido.AgentServer.start_link(server_opts)

    feed_signal =
      Jido.Signal.new!(
        "runic.feed",
        %{data: %{topic: topic, audience: "general", num_queries: 3}},
        source: "/studio/orchestrator"
      )

    Jido.AgentServer.cast(pid, feed_signal)

    completion = Jido.AgentServer.await_completion(pid, timeout: timeout)

    {:ok, server_state} = Jido.AgentServer.state(pid)
    agent = server_state.agent
    strat = StratState.get(agent)

    events =
      case Jido.AgentServer.recent_events(pid) do
        {:ok, evts} -> evts
        _ -> []
      end

    {status, productions, facts} =
      case completion do
        {:ok, %{status: :completed}} ->
          {:completed, Workflow.raw_productions(strat.workflow), Workflow.facts(strat.workflow)}

        {:ok, %{status: :failed}} ->
          {:failed, [], Workflow.facts(strat.workflow)}

        {:error, _reason} ->
          {:error, [], []}
      end

    if jido_started? do
      Jido.stop(jido)
    end

    %{
      topic: topic,
      productions: productions,
      facts: facts,
      status: status,
      events: events,
      pid: pid
    }
  end

  @doc """
  Extract the final article from run results.
  """
  def article(%{productions: productions}) do
    productions
    |> Enum.filter(fn
      %{markdown: _} -> true
      _ -> false
    end)
    |> List.last()
  end

  @doc """
  Trace provenance for a given fact through run results.
  Returns the chain of facts from root to leaf.
  """
  def trace_provenance(%{facts: facts}, target_hash) do
    facts_by_hash = Map.new(facts, fn f -> {f.hash, f} end)
    do_trace(facts_by_hash, target_hash, [])
  end

  defp do_trace(_facts_map, nil, acc), do: Enum.reverse(acc)

  defp do_trace(facts_map, hash, acc) do
    case Map.get(facts_map, hash) do
      nil ->
        Enum.reverse(acc)

      fact ->
        parent_hash =
          case fact.ancestry do
            {_producer, parent} -> parent
            _ -> nil
          end

        do_trace(facts_map, parent_hash, [fact | acc])
    end
  end
end
