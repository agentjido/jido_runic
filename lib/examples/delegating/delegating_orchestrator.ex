defmodule Jido.Runic.Examples.Delegating.DelegatingOrchestrator do
  @moduledoc """
  Multi-agent orchestrator that delegates workflow nodes to child agents.

  Demonstrates Jido's multi-agent orchestration (SpawnAgent, emit_to_pid,
  emit_to_parent) integrated with Runic's workflow engine. Lightweight nodes
  run locally while heavy nodes are delegated to specialized child agents.

  ## Pipeline

      PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble
                    (local)           (local)        (child: drafter)  (child: editor)

  ## Execution Flow

  1. Orchestrator starts, workflow runs PlanQueries → SimulateSearch → BuildOutline locally
  2. When DraftArticle becomes runnable, strategy emits `SpawnAgent` for `:drafter`
  3. On `jido.agent.child.started`, sends the runnable to the child via `emit_to_pid`
  4. Child (`Jido.Runic.ChildWorker`) executes via `RunnableExecution`, emits result to parent
  5. Parent receives result, applies it to workflow, advancing to EditAndAssemble
  6. Same pattern repeats for EditAndAssemble with a second ChildWorker
  7. Workflow completes normally
  """

  require Logger

  use Jido.Agent,
    name: "delegating_orchestrator",
    strategy:
      {Jido.Runic.Strategy,
       workflow_fn: &__MODULE__.build_workflow/0,
       child_modules: %{
         drafter: Jido.Runic.ChildWorker,
         editor: Jido.Runic.ChildWorker
       }},
    schema: []

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Runic.ActionNode
  alias Runic.Workflow

  alias Jido.Runic.Examples.Studio.Actions.{
    PlanQueries,
    SimulateSearch,
    BuildOutline,
    DraftArticle,
    EditAndAssemble
  }

  @doc "Build the workflow DAG with delegated nodes for drafting and editing."
  def build_workflow do
    draft_node =
      ActionNode.new(DraftArticle, %{}, name: :draft_article, executor: {:child, :drafter})

    edit_node =
      ActionNode.new(EditAndAssemble, %{}, name: :edit_and_assemble, executor: {:child, :editor})

    Workflow.new(name: :delegating_pipeline)
    |> Workflow.add(PlanQueries)
    |> Workflow.add(SimulateSearch, to: :plan_queries)
    |> Workflow.add(BuildOutline, to: :simulate_search)
    |> Workflow.add(draft_node, to: :build_outline)
    |> Workflow.add(edit_node, to: :draft_article)
  end

  @doc """
  Run the full delegating pipeline for a topic.

  ## Options

    * `:jido` - Name of a running Jido instance (required)
    * `:timeout` - Timeout in ms for `await_completion` (default: 120_000)
    * `:debug` - Enable debug event buffer (default: true)

  ## Returns

  A map with `:topic`, `:productions`, `:status`, and `:pid`.
  """
  @spec run(String.t(), keyword()) :: map()
  def run(topic, opts \\ []) do
    jido = Keyword.fetch!(opts, :jido)
    timeout = Keyword.get(opts, :timeout, 120_000)
    debug = Keyword.get(opts, :debug, true)

    Logger.info("[Delegating] Starting pipeline for topic: #{inspect(topic)}")

    server_opts = [agent: __MODULE__, jido: jido, debug: debug]
    {:ok, pid} = Jido.AgentServer.start_link(server_opts)

    feed_signal =
      Jido.Signal.new!(
        "runic.feed",
        %{data: %{topic: topic}},
        source: "/delegating/orchestrator"
      )

    Jido.AgentServer.cast(pid, feed_signal)

    case Jido.AgentServer.await_completion(pid, timeout: timeout) do
      {:ok, %{status: :completed}} ->
        {:ok, server_state} = Jido.AgentServer.state(pid)
        strat = StratState.get(server_state.agent)
        productions = Workflow.raw_productions(strat.workflow)

        Logger.info("[Delegating] Pipeline COMPLETED — #{length(productions)} productions")

        %{
          topic: topic,
          productions: productions,
          status: :completed,
          pid: pid
        }

      {:ok, %{status: :failed}} ->
        Logger.error("[Delegating] Pipeline FAILED")
        %{topic: topic, productions: [], status: :failed, pid: pid}

      {:error, reason} ->
        Logger.error("[Delegating] Pipeline ERROR: #{inspect(reason)}")
        %{topic: topic, productions: [], status: {:error, reason}, pid: pid}
    end
  end

  @doc "Extract the final article markdown from run results."
  def article(%{productions: productions}) do
    productions
    |> Enum.filter(fn
      %{markdown: _} -> true
      _ -> false
    end)
    |> List.last()
  end
end
