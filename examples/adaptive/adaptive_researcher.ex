defmodule Jido.Runic.Examples.Adaptive.AdaptiveResearcher do
  @moduledoc """
  Adaptive research agent demonstrating dynamic workflow construction.

  Unlike the Studio `OrchestratorAgent` which uses a fixed 5-node pipeline,
  this agent dynamically selects its Phase 2 writing pipeline based on
  Phase 1 research results:

  - **Phase 1** — `PlanQueries → SimulateSearch`
  - **Phase 2 (rich)** — `BuildOutline → DraftArticle → EditAndAssemble`
  - **Phase 2 (thin)** — `DraftArticle → EditAndAssemble`

  The agent uses the standard `Jido.Runic.Strategy` with `runic.set_workflow`
  to hot-swap workflows between phases.
  """

  require Logger

  use Jido.Agent,
    name: "adaptive_researcher",
    strategy: {Jido.Runic.Strategy, workflow_fn: &__MODULE__.build_phase_1/0},
    schema: []

  @doc false
  @spec plugin_specs() :: [Jido.Plugin.Spec.t()]
  def plugin_specs, do: []

  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow

  alias Jido.Runic.Examples.Studio.Actions.{
    PlanQueries,
    SimulateSearch,
    BuildOutline,
    DraftArticle,
    EditAndAssemble
  }

  @rich_threshold 500

  @doc "Build the Phase 1 research workflow: PlanQueries → SimulateSearch."
  def build_phase_1 do
    Workflow.new(name: :phase_1_research)
    |> Workflow.add(PlanQueries)
    |> Workflow.add(SimulateSearch, to: :plan_queries)
  end

  @doc """
  Build the Phase 2 writing workflow, dynamically shaped by research results.

  When the research summary is rich (>= #{@rich_threshold} chars), includes
  an outline step. Otherwise skips straight to drafting.
  """
  def build_phase_2(productions) do
    research_summary = extract_research_summary(productions)
    rich? = String.length(research_summary) >= @rich_threshold

    if rich? do
      Logger.info("[Adaptive] Rich results (#{String.length(research_summary)} chars) — full pipeline")

      Workflow.new(name: :phase_2_full)
      |> Workflow.add(BuildOutline)
      |> Workflow.add(DraftArticle, to: :build_outline)
      |> Workflow.add(EditAndAssemble, to: :draft_article)
    else
      Logger.info("[Adaptive] Thin results (#{String.length(research_summary)} chars) — skipping outline")

      Workflow.new(name: :phase_2_slim)
      |> Workflow.add(DraftArticle)
      |> Workflow.add(EditAndAssemble, to: :draft_article)
    end
  end

  @doc """
  Run the full adaptive research pipeline for a topic.

  Phase 1 researches the topic, then Phase 2's shape is determined
  by how rich the research results are.

  ## Options

    * `:jido` - Name of a running Jido instance (required)
    * `:timeout` - Timeout in ms for each phase (default: 120_000)
    * `:debug` - Enable debug event buffer (default: true)

  ## Returns

  A map with `:topic`, `:productions`, `:phase_2_type`, `:status`, and `:pid`.
  """
  @spec run(String.t(), keyword()) :: map()
  def run(topic, opts \\ []) do
    jido = Keyword.fetch!(opts, :jido)
    timeout = Keyword.get(opts, :timeout, 120_000)
    debug = Keyword.get(opts, :debug, true)

    Logger.info("[Adaptive] Starting adaptive pipeline for topic: #{inspect(topic)}")

    server_opts = [agent: __MODULE__, jido: jido, debug: debug]
    {:ok, pid} = Jido.AgentServer.start_link(server_opts)

    # Phase 1: Research
    Logger.info("[Adaptive] Phase 1: PlanQueries → SimulateSearch")

    feed_signal =
      Jido.Signal.new!(
        "runic.feed",
        %{data: %{topic: topic}},
        source: "/adaptive/researcher"
      )

    Jido.AgentServer.cast(pid, feed_signal)

    case Jido.AgentServer.await_completion(pid, timeout: timeout) do
      {:ok, %{status: :completed}} ->
        :ok

      {:ok, %{status: :failed}} ->
        Logger.error("[Adaptive] Phase 1 FAILED")
        return_error(pid, topic, :phase_1_failed)

      {:error, reason} ->
        Logger.error("[Adaptive] Phase 1 ERROR: #{inspect(reason)}")
        return_error(pid, topic, reason)
    end

    {:ok, server_state} = Jido.AgentServer.state(pid)
    strat = StratState.get(server_state.agent)
    phase_1_productions = Workflow.raw_productions(strat.workflow)

    Logger.info("[Adaptive] Phase 1 complete — #{length(phase_1_productions)} productions")

    # Build Phase 2 dynamically
    phase_2_workflow = build_phase_2(phase_1_productions)
    phase_2_type = if phase_2_workflow.name == :phase_2_full, do: :full, else: :slim

    # Hot-swap workflow
    set_workflow_signal =
      Jido.Signal.new!(
        "runic.set_workflow",
        %{workflow: phase_2_workflow},
        source: "/adaptive/researcher"
      )

    Jido.AgentServer.cast(pid, set_workflow_signal)
    Process.sleep(50)

    # Feed Phase 1 productions into Phase 2
    phase_2_input = reshape_for_phase_2(phase_1_productions, phase_2_type)

    feed_phase_2 =
      Jido.Signal.new!(
        "runic.feed",
        %{data: phase_2_input},
        source: "/adaptive/researcher"
      )

    Logger.info("[Adaptive] Phase 2 (#{phase_2_type}): feeding research data")
    Jido.AgentServer.cast(pid, feed_phase_2)

    case Jido.AgentServer.await_completion(pid, timeout: timeout) do
      {:ok, %{status: :completed}} ->
        {:ok, final_state} = Jido.AgentServer.state(pid)
        final_strat = StratState.get(final_state.agent)
        productions = Workflow.raw_productions(final_strat.workflow)

        Logger.info("[Adaptive] Phase 2 complete — #{length(productions)} productions")

        %{
          topic: topic,
          productions: productions,
          phase_1_productions: phase_1_productions,
          phase_2_type: phase_2_type,
          status: :completed,
          pid: pid
        }

      {:ok, %{status: :failed}} ->
        Logger.error("[Adaptive] Phase 2 FAILED")
        return_error(pid, topic, :phase_2_failed)

      {:error, reason} ->
        Logger.error("[Adaptive] Phase 2 ERROR: #{inspect(reason)}")
        return_error(pid, topic, reason)
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

  # -- Private Helpers ---------------------------------------------------------

  defp extract_research_summary(productions) do
    Enum.find_value(productions, "", fn
      %{research_summary: summary} when is_binary(summary) -> summary
      _ -> nil
    end)
  end

  defp reshape_for_phase_2(productions, :full) do
    topic =
      Enum.find_value(productions, "Unknown", fn
        %{topic: t} when is_binary(t) -> t
        _ -> nil
      end)

    research_summary = extract_research_summary(productions)
    %{topic: topic, research_summary: research_summary}
  end

  defp reshape_for_phase_2(productions, :slim) do
    topic =
      Enum.find_value(productions, "Unknown", fn
        %{topic: t} when is_binary(t) -> t
        _ -> nil
      end)

    research_summary = extract_research_summary(productions)
    %{topic: topic, outline: [research_summary]}
  end

  defp return_error(pid, topic, reason) do
    %{
      topic: topic,
      productions: [],
      phase_1_productions: [],
      phase_2_type: nil,
      status: {:error, reason},
      pid: pid
    }
  end
end
