defmodule Jido.Runic.Examples.Studio.OrchestratorAgent do
  @moduledoc """
  Orchestrator agent for the AI Research Studio.

  Provides two entrypoints for the same 5-node LLM pipeline:

  - `run/2` — Auto mode. Feeds a topic and awaits completion in one shot.
  - `run_step/2` — Step mode. Pauses between each node, providing full
    introspection (annotated graph, step history, input/output data) at
    every transition. Accepts an `:on_step` callback for UI integration.

  The workflow DAG is passed to the strategy via
  `strategy: {Jido.Runic.Strategy, workflow_fn: &build_workflow/0}` — the strategy
  receives it in `init/2` so no `set_workflow` signal is needed at runtime.

  Pipeline: PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble
  """

  require Logger

  use Jido.Agent,
    name: "studio_orchestrator",
    strategy: {Jido.Runic.Strategy, workflow_fn: &__MODULE__.build_workflow/0},
    schema: []

  alias Jido.Runic.Introspection
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow

  alias Jido.Runic.Examples.Studio.Actions.{
    PlanQueries,
    SimulateSearch,
    BuildOutline,
    DraftArticle,
    EditAndAssemble
  }

  @doc "Build the 5-node linear Runic DAG for the research pipeline."
  def build_workflow do
    Workflow.new(name: :research_studio)
    |> Workflow.add(PlanQueries)
    |> Workflow.add(SimulateSearch, to: :plan_queries)
    |> Workflow.add(BuildOutline, to: :simulate_search)
    |> Workflow.add(DraftArticle, to: :build_outline)
    |> Workflow.add(EditAndAssemble, to: :draft_article)
  end

  @doc """
  Run the full research pipeline for a topic through an AgentServer.

  ## Options

    * `:jido` - Name of a running Jido instance (required)
    * `:timeout` - Timeout in ms for `await_completion` (default: 120_000)
    * `:debug` - Enable debug event buffer (default: true)

  ## Returns

  A map with `:topic`, `:productions`, `:facts`, `:status`, `:events`, and `:pid`.
  """
  @spec run(String.t(), keyword()) :: map()
  def run(topic, opts \\ []) do
    jido = Keyword.fetch!(opts, :jido)
    timeout = Keyword.get(opts, :timeout, 120_000)
    debug = Keyword.get(opts, :debug, true)

    Logger.info("[Studio] Starting research pipeline for topic: #{inspect(topic)}")
    Logger.info("[Studio] Timeout: #{timeout}ms, Debug: #{debug}")

    server_opts = [agent: __MODULE__, jido: jido, debug: debug]
    {:ok, pid} = Jido.AgentServer.start_link(server_opts)
    Logger.info("[Studio] AgentServer started: #{inspect(pid)}")

    Logger.info("[Studio] Workflow DAG: PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble")

    feed_signal =
      Jido.Signal.new!(
        "runic.feed",
        %{data: %{topic: topic}},
        source: "/studio/orchestrator"
      )

    Logger.info("[Studio] Feeding signal: runic.feed with topic=#{inspect(topic)}")
    Jido.AgentServer.cast(pid, feed_signal)

    Logger.info("[Studio] Awaiting completion (timeout: #{timeout}ms)...")
    t0 = System.monotonic_time(:millisecond)
    completion = Jido.AgentServer.await_completion(pid, timeout: timeout)
    elapsed = System.monotonic_time(:millisecond) - t0

    Logger.info("[Studio] await_completion returned after #{elapsed}ms: #{inspect_completion(completion)}")

    {:ok, server_state} = Jido.AgentServer.state(pid)
    agent = server_state.agent
    strat = StratState.get(agent)

    log_strategy_state(strat)

    events =
      case Jido.AgentServer.recent_events(pid) do
        {:ok, evts} ->
          Logger.debug("[Studio] Collected #{length(evts)} debug events")
          log_events(evts)
          evts

        {:error, reason} ->
          Logger.warning("[Studio] Could not fetch events: #{inspect(reason)}")
          []
      end

    {status, productions, facts} =
      case completion do
        {:ok, %{status: :completed}} ->
          prods = Workflow.raw_productions(strat.workflow)
          fcts = Workflow.facts(strat.workflow)
          Logger.info("[Studio] Pipeline COMPLETED — #{length(prods)} productions, #{length(fcts)} facts")
          {:completed, prods, fcts}

        {:ok, %{status: :failed}} ->
          fcts = Workflow.facts(strat.workflow)
          Logger.error("[Studio] Pipeline FAILED — #{length(fcts)} facts accumulated before failure")
          {:failed, [], fcts}

        {:error, reason} ->
          Logger.error("[Studio] Pipeline ERROR: #{inspect(reason)}")
          {:error, [], []}
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

  @doc "Extract the final article markdown from run results."
  def article(%{productions: productions}) do
    productions
    |> Enum.filter(fn
      %{markdown: _} -> true
      _ -> false
    end)
    |> List.last()
  end

  @doc """
  Run the research pipeline in step mode with full introspection.

  Starts the same 5-node pipeline but pauses between each step, logging
  the workflow state, node inputs/outputs, and annotated graph at each
  transition. Useful for debugging, demos, and building low-code UIs.

  ## Options

    * `:jido` - Name of a running Jido instance (required)
    * `:timeout` - Per-step timeout in ms (default: 120_000)
    * `:debug` - Enable debug event buffer (default: true)
    * `:on_step` - Optional callback `fn step_info -> :ok end` invoked
      after each step completes, receiving a map with `:step_index`,
      `:node`, `:input`, `:output`, `:status`, `:graph`, and `:summary`.

  ## Returns

  A map with `:topic`, `:productions`, `:status`, `:steps` (list of per-step
  info maps), `:summary`, and `:pid`.
  """
  @spec run_step(String.t(), keyword()) :: map()
  def run_step(topic, opts \\ []) do
    jido = Keyword.fetch!(opts, :jido)
    timeout = Keyword.get(opts, :timeout, 120_000)
    debug = Keyword.get(opts, :debug, true)
    on_step = Keyword.get(opts, :on_step)

    Logger.info("[Studio:Step] Starting step-mode pipeline for topic: #{inspect(topic)}")

    server_opts = [agent: __MODULE__, jido: jido, debug: debug]
    {:ok, pid} = Jido.AgentServer.start_link(server_opts)

    set_mode_signal = Jido.Signal.new!("runic.set_mode", %{mode: :step}, source: "/studio/step")
    Jido.AgentServer.cast(pid, set_mode_signal)
    Process.sleep(50)

    feed_signal =
      Jido.Signal.new!(
        "runic.feed",
        %{data: %{topic: topic}},
        source: "/studio/step"
      )

    Jido.AgentServer.cast(pid, feed_signal)
    Process.sleep(50)

    steps = step_loop(pid, topic, timeout, on_step, 0, [])

    {:ok, server_state} = Jido.AgentServer.state(pid)
    agent = server_state.agent
    strat = StratState.get(agent)

    summary = Introspection.execution_summary(strat.workflow)
    graph = Introspection.annotated_graph(strat.workflow, strat)

    productions =
      if strat.status == :success,
        do: Workflow.raw_productions(strat.workflow),
        else: []

    Logger.info(
      "[Studio:Step] Pipeline #{strat.status} — #{length(steps)} steps, " <>
        "#{length(productions)} productions"
    )

    %{
      topic: topic,
      productions: productions,
      status: strat.status,
      steps: Enum.reverse(steps),
      step_history: strat.step_history,
      summary: summary,
      graph: graph,
      pid: pid
    }
  end

  # -- Debug Helpers -----------------------------------------------------------

  defp inspect_completion({:ok, %{status: status}}), do: "ok/#{status}"
  defp inspect_completion({:error, {:timeout, diag}}), do: "timeout (#{inspect(diag)})"
  defp inspect_completion({:error, reason}), do: "error: #{inspect(reason)}"

  defp log_strategy_state(strat) do
    Logger.info(
      "[Studio] Strategy state: status=#{strat.status}, " <>
        "pending=#{map_size(strat.pending)}, " <>
        "queued=#{length(strat.queued)}, " <>
        "ran_nodes=#{MapSet.size(strat.ran_nodes)}, " <>
        "productions=#{length(Workflow.raw_productions(strat.workflow))}"
    )
  end

  defp log_events(events) do
    events
    |> Enum.take(20)
    |> Enum.each(fn event ->
      type = Map.get(event, :type, :unknown)
      data = Map.get(event, :data, %{})
      detail = summarize_event(type, data)
      Logger.debug("[Studio] Event: #{type} #{detail}")
    end)
  end

  defp summarize_event(:signal_received, %{signal_type: t}), do: "type=#{t}"
  defp summarize_event(:directive_started, %{directive_type: t}), do: "directive=#{t}"
  defp summarize_event(_type, data), do: inspect(data, limit: 3, printable_limit: 80)

  # -- Step-Mode Loop ----------------------------------------------------------

  defp step_loop(pid, _topic, timeout, on_step, step_index, steps) do
    {:ok, server_state} = Jido.AgentServer.state(pid)
    strat = StratState.get(server_state.agent)

    if strat.status in [:success, :failure] do
      steps
    else
      case strat.status do
        :paused ->
          do_step(pid, strat, timeout, on_step, step_index, steps)

        :running ->
          case await_paused(pid, timeout, 50) do
            {:ok, strat} ->
              if strat.status in [:success, :failure] do
                steps
              else
                do_step(pid, strat, timeout, on_step, step_index, steps)
              end

            {:error, :timeout} ->
              Logger.error("[Studio:Step] Timed out waiting for pause at step #{step_index}")
              steps
          end

        _ ->
          steps
      end
    end
  end

  defp do_step(pid, strat, timeout, on_step, step_index, steps) do
    graph_before = Introspection.annotated_graph(strat.workflow, strat)

    Logger.info(
      "[Studio:Step] Step #{step_index}: #{length(strat.held_runnables)} runnable(s) held"
    )

    held_names =
      Enum.map(strat.held_runnables, fn r -> r.node.name end)

    Logger.info("[Studio:Step]   Nodes: #{inspect(held_names)}")

    step_signal = Jido.Signal.new!("runic.step", %{}, source: "/studio/step")
    Jido.AgentServer.cast(pid, step_signal)

    case await_paused(pid, timeout, 100) do
      {:ok, new_strat} ->
        new_history = new_strat.step_history
        prev_history = strat.step_history

        new_entries =
          Enum.take(new_history, length(new_history) - length(prev_history))

        graph_after = Introspection.annotated_graph(new_strat.workflow, new_strat)
        summary = Introspection.execution_summary(new_strat.workflow)

        step_info = %{
          step_index: step_index,
          nodes_dispatched: held_names,
          completed_entries: new_entries,
          graph_before: graph_before,
          graph_after: graph_after,
          summary: summary,
          status: new_strat.status
        }

        Enum.each(new_entries, fn entry ->
          Logger.info(
            "[Studio:Step]   #{entry.node} → #{entry.status}" <>
              if(entry.output, do: " (output keys: #{inspect(Map.keys(entry.output))})", else: "")
          )
        end)

        if on_step, do: on_step.(step_info)

        step_loop(pid, nil, timeout, on_step, step_index + 1, [step_info | steps])

      {:error, :timeout} ->
        Logger.error("[Studio:Step] Timed out at step #{step_index}")
        steps
    end
  end

  defp await_paused(pid, timeout, interval) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      {:ok, server_state} = Jido.AgentServer.state(pid)
      strat = StratState.get(server_state.agent)

      if strat.status in [:paused, :success, :failure] do
        {:done, strat}
      else
        Process.sleep(interval)
        :continue
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:done, strat}, _acc ->
        {:halt, {:ok, strat}}

      :continue, _acc ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, {:error, :timeout}}
        else
          {:cont, nil}
        end
    end)
  end
end
