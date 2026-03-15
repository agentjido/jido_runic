defmodule Jido.Runic.Examples.Branching.LLMBranchingOrchestrator do
  @moduledoc """
  Adaptive routing example driven by structured LLM output.

  Phase 1 runs a router node that returns a structured decision:

  - `question` (string)
  - `route` (`:direct | :analysis | :safe`)
  - `detail_level` (`:brief | :detailed`)
  - `confidence` (float)
  - `reasoning` (string)

  The workflow is then hot-swapped to one of three phase-2 DAGs:

  - `:direct` -> single-node quick answer
  - `:analysis` -> two-node deep analysis (plan + synthesis)
  - `:safe` -> safe fallback response
  """

  require Logger

  use Jido.Agent,
    name: "llm_branching_orchestrator",
    strategy: {Jido.Runic.Strategy, workflow_fn: &__MODULE__.build_phase_1/0},
    schema: []

  @doc false
  @spec plugin_specs() :: [Jido.Plugin.Spec.t()]
  def plugin_specs, do: []

  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow

  alias Jido.Runic.Examples.Branching.Actions.{
    AnalysisAnswer,
    AnalysisPlan,
    DirectAnswer,
    RouteQuestion,
    SafeResponse
  }

  @type route :: :direct | :analysis | :safe

  @doc "Build the phase 1 workflow that asks the LLM router for structured route output."
  def build_phase_1 do
    Workflow.new(name: :phase_1_decide)
    |> Workflow.add(RouteQuestion)
  end

  @doc """
  Build phase 2 workflow dynamically from the route decision.

  - `:direct` -> `DirectAnswer`
  - `:analysis` -> `AnalysisPlan -> AnalysisAnswer`
  - `:safe` -> `SafeResponse`
  """
  @spec build_phase_2(route()) :: struct()
  def build_phase_2(:direct) do
    Workflow.new(name: :phase_2_direct)
    |> Workflow.add(DirectAnswer)
  end

  def build_phase_2(:analysis) do
    Workflow.new(name: :phase_2_analysis)
    |> Workflow.add(AnalysisPlan)
    |> Workflow.add(AnalysisAnswer, to: :analysis_plan)
  end

  def build_phase_2(:safe) do
    Workflow.new(name: :phase_2_safe)
    |> Workflow.add(SafeResponse)
  end

  @doc """
  Run the two-phase structured branching demo.

  ## Options

    * `:jido` - Name of a running Jido instance (required)
    * `:timeout` - Timeout in ms for each phase (default: `120_000`)
    * `:debug` - Enable debug event buffer (default: `true`)

  ## Returns

  A map with `:decision`, `:selected_branch`, `:productions`, and `:status`.
  """
  @spec run(String.t(), keyword()) :: map()
  def run(question, opts \\ []) do
    jido = Keyword.fetch!(opts, :jido)
    timeout = Keyword.get(opts, :timeout, 120_000)
    debug = Keyword.get(opts, :debug, true)

    Logger.info("[Branching] Starting structured branch demo for question: #{inspect(question)}")

    {:ok, pid} = Jido.AgentServer.start_link(agent: __MODULE__, jido: jido, debug: debug)

    feed_phase_1 =
      Jido.Signal.new!(
        "runic.feed",
        %{data: %{question: question}},
        source: "/branching/orchestrator"
      )

    Jido.AgentServer.cast(pid, feed_phase_1)

    case Jido.AgentServer.await_completion(pid, timeout: timeout) do
      {:ok, %{status: :completed}} ->
        run_phase_2(pid, question, timeout)

      {:ok, %{status: :failed}} ->
        Logger.error("[Branching] Phase 1 FAILED")
        error_result(pid, question, :phase_1_failed)

      {:error, reason} ->
        Logger.error("[Branching] Phase 1 ERROR: #{inspect(reason)}")
        error_result(pid, question, reason)
    end
  end

  @doc "Extract the final branch output from run results."
  @spec branch_output(map()) :: map() | nil
  def branch_output(%{productions: productions}) do
    productions
    |> Enum.filter(fn
      %{branch_result: _} -> true
      _ -> false
    end)
    |> List.last()
  end

  # -- Private Helpers ---------------------------------------------------------

  defp run_phase_2(pid, question, timeout) do
    {:ok, server_state} = Jido.AgentServer.state(pid)
    strat = StratState.get(server_state.agent)
    phase_1_productions = Workflow.raw_productions(strat.workflow)

    decision = extract_decision(phase_1_productions, question)
    phase_2_workflow = build_phase_2(decision.route)
    selected_branch = decision.route

    Logger.info(
      "[Branching] Route=#{decision.route} detail=#{decision.detail_level} confidence=#{format(decision.confidence)} branch=#{selected_branch}"
    )

    set_workflow_signal =
      Jido.Signal.new!(
        "runic.set_workflow",
        %{workflow: phase_2_workflow},
        source: "/branching/orchestrator"
      )

    Jido.AgentServer.cast(pid, set_workflow_signal)
    Process.sleep(50)

    feed_phase_2 =
      Jido.Signal.new!(
        "runic.feed",
        %{data: decision},
        source: "/branching/orchestrator"
      )

    Jido.AgentServer.cast(pid, feed_phase_2)

    case Jido.AgentServer.await_completion(pid, timeout: timeout) do
      {:ok, %{status: :completed}} ->
        {:ok, final_state} = Jido.AgentServer.state(pid)
        final_strat = StratState.get(final_state.agent)
        productions = Workflow.raw_productions(final_strat.workflow)

        %{
          question: question,
          decision: decision,
          selected_branch: selected_branch,
          productions: productions,
          phase_1_productions: phase_1_productions,
          status: :completed,
          pid: pid
        }

      {:ok, %{status: :failed}} ->
        Logger.error("[Branching] Phase 2 FAILED")
        error_result(pid, question, :phase_2_failed)

      {:error, reason} ->
        Logger.error("[Branching] Phase 2 ERROR: #{inspect(reason)}")
        error_result(pid, question, reason)
    end
  end

  defp extract_decision(productions, fallback_question) do
    decision =
      Enum.find(productions, fn
        %{route: route} when route in [:direct, :analysis, :safe] -> true
        _ -> false
      end) || %{}

    %{
      question: Map.get(decision, :question, fallback_question),
      route: normalize_route(Map.get(decision, :route, :analysis)),
      detail_level: normalize_detail_level(Map.get(decision, :detail_level, :brief)),
      confidence: normalize_confidence(Map.get(decision, :confidence, 0.5)),
      reasoning: Map.get(decision, :reasoning, "No routing rationale provided.")
    }
  end

  defp error_result(pid, question, reason) do
    %{
      question: question,
      decision: nil,
      selected_branch: nil,
      productions: [],
      phase_1_productions: [],
      status: {:error, reason},
      pid: pid
    }
  end

  defp format(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp normalize_route(route) when route in [:direct, :analysis, :safe], do: route
  defp normalize_route(_), do: :analysis

  defp normalize_detail_level(level) when level in [:brief, :detailed], do: level
  defp normalize_detail_level(_), do: :brief

  defp normalize_confidence(value) when is_integer(value),
    do: value |> Kernel./(1.0) |> clamp_confidence()

  defp normalize_confidence(value) when is_float(value), do: clamp_confidence(value)
  defp normalize_confidence(_), do: 0.5

  defp clamp_confidence(value), do: min(1.0, max(0.0, value))
end
