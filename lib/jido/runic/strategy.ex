defmodule Jido.Runic.Strategy do
  @moduledoc """
  A Jido execution strategy powered by a Runic Workflow DAG.

  Incoming signals are converted to Runic Facts and fed into a workflow.
  Runnables are emitted as ExecuteRunnable directives for the runtime.
  Completed runnables are applied back, advancing the workflow until quiescence.

  ## Status Lifecycle

      :idle → :running → :waiting → :paused → :success / :failure

  - `:idle` — No workflow activity, waiting for input.
  - `:running` — Runnables dispatched, awaiting completions.
  - `:waiting` — Workflow has pending edges (unsatisfied Join) but
    no dispatchable runnables. Waiting for external signal.
  - `:paused` — Step mode: runnables are ready but held until an
    explicit `runic.step` or `runic.resume` signal advances execution.
  - `:success` — Workflow quiesced with productions. Terminal.
  - `:failure` — All paths exhausted, no productions. Terminal.

  ## Execution Modes

  The strategy supports two execution modes controlled by `execution_mode`:

  - `:auto` (default) — Runnables are dispatched automatically as they
    become available. This is the standard fire-and-forget behaviour.
  - `:step` — After feeding a signal or applying a result, the strategy
    pauses instead of dispatching. Use `runic.step` to advance one
    generation at a time, or `runic.resume` to switch back to `:auto`.

  ### Step-Mode Signals

  - `"runic.step"` — Dispatches the next batch of held runnables and
    returns to `:paused` (or terminal) once their results are applied.
  - `"runic.resume"` — Switches to `:auto` mode and dispatches all
    held runnables, continuing normally.
  - `"runic.set_mode"` — Sets `execution_mode` to `:auto` or `:step`.

  ### Step History

  When in `:step` mode, each completed runnable is recorded in
  `step_history` with node name, action module, input/output values,
  status, and a monotonic timestamp.

  ## Concurrency Control

  `max_concurrent` limits how many runnables are dispatched simultaneously.
  Excess runnables are queued and drained via `tick/2`.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Runic.Workflow.Fact
  alias Jido.Runic.SignalFact
  alias Jido.Runic.Directive.ExecuteRunnable

  @action_specs %{
    :runic_feed_signal => %{
      schema:
        Zoi.object(%{
          data: Zoi.any(),
          signal: Zoi.any() |> Zoi.optional()
        }),
      doc: "Feed a signal into the Runic workflow",
      name: "runic.feed_signal"
    },
    :runic_apply_result => %{
      schema: Zoi.object(%{runnable: Zoi.any()}),
      doc: "Apply a completed or failed runnable result to the workflow",
      name: "runic.apply_result"
    },
    :runic_set_workflow => %{
      schema: Zoi.object(%{workflow: Zoi.any()}),
      doc: "Set the active workflow",
      name: "runic.set_workflow"
    },
    :runic_step => %{
      schema: Zoi.object(%{}),
      doc: "Advance one generation in step mode (dispatch held runnables, then pause)",
      name: "runic.step"
    },
    :runic_resume => %{
      schema: Zoi.object(%{}),
      doc: "Switch to auto mode and dispatch all held runnables",
      name: "runic.resume"
    },
    :runic_set_mode => %{
      schema:
        Zoi.object(%{
          mode: Zoi.enum([:auto, :step])
        }),
      doc: "Set the execution mode to :auto or :step",
      name: "runic.set_mode"
    }
  }

  @impl true
  def action_spec(action), do: Map.get(@action_specs, action)

  @impl true
  def signal_routes(_ctx) do
    [
      {"runic.feed", {:strategy_cmd, :runic_feed_signal}},
      {"runic.runnable.completed", {:strategy_cmd, :runic_apply_result}},
      {"runic.runnable.failed", {:strategy_cmd, :runic_apply_result}},
      {"runic.set_workflow", {:strategy_cmd, :runic_set_workflow}},
      {"runic.step", {:strategy_cmd, :runic_step}},
      {"runic.resume", {:strategy_cmd, :runic_resume}},
      {"runic.set_mode", {:strategy_cmd, :runic_set_mode}}
    ]
  end

  @impl true
  def init(agent, ctx) do
    strategy_opts = ctx[:strategy_opts] || []

    workflow =
      case Keyword.get(strategy_opts, :workflow) do
        nil ->
          case Keyword.get(strategy_opts, :workflow_fn) do
            fun when is_function(fun, 0) -> fun.()
            _ -> nil
          end

        wf ->
          wf
      end

    strat_state = StratState.get(agent, nil)

    if strat_state && Map.get(strat_state, :workflow) do
      {agent, []}
    else
      strat = %{
        workflow: workflow || Workflow.new(:default),
        status: :idle,
        pending: %{},
        max_concurrent: Keyword.get(strategy_opts, :max_concurrent, :infinity),
        queued: [],
        ran_nodes: MapSet.new(),
        execution_mode: Keyword.get(strategy_opts, :execution_mode, :auto),
        step_history: [],
        held_runnables: []
      }

      {StratState.put(agent, strat), []}
    end
  end

  @impl true
  def cmd(agent, instructions, _ctx) do
    Enum.reduce(instructions, {agent, []}, fn instruction, {agent_acc, directives_acc} ->
      {updated_agent, new_directives} = handle_instruction(agent_acc, instruction)
      {updated_agent, directives_acc ++ new_directives}
    end)
  end

  @impl true
  def snapshot(agent, _ctx) do
    strat = StratState.get(agent, %{})
    workflow = Map.get(strat, :workflow)
    status = Map.get(strat, :status, :idle)
    step_history = Map.get(strat, :step_history, [])

    current_node =
      case step_history do
        [latest | _] -> Map.get(latest, :node)
        _ -> nil
      end

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:success, :failure],
      result: if(status == :success and workflow, do: Workflow.raw_productions(workflow)),
      details: %{
        pending_count: map_size(Map.get(strat, :pending, %{})),
        queued_count: length(Map.get(strat, :queued, [])),
        is_runnable: workflow && Workflow.is_runnable?(workflow),
        productions_count:
          if(workflow, do: length(Workflow.raw_productions(workflow)), else: 0),
        execution_mode: Map.get(strat, :execution_mode, :auto),
        step_history: step_history,
        held_count: length(Map.get(strat, :held_runnables, [])),
        current_node: current_node
      }
    }
  end

  @impl true
  def tick(agent, _ctx) do
    strat = StratState.get(agent, nil)

    cond do
      strat && strat.queued != [] &&
          (strat.max_concurrent == :infinity ||
             map_size(strat.pending) < strat.max_concurrent) ->
        {to_dispatch, remaining} =
          if strat.max_concurrent == :infinity do
            {strat.queued, []}
          else
            Enum.split(strat.queued, strat.max_concurrent - map_size(strat.pending))
          end

        directives = Enum.map(to_dispatch, &build_directive/1)

        pending =
          Enum.reduce(to_dispatch, strat.pending, fn r, acc ->
            Map.put(acc, r.id, r)
          end)

        agent = StratState.put(agent, %{strat | pending: pending, queued: remaining})
        {agent, directives}

      strat && strat.status == :running && Workflow.is_runnable?(strat.workflow) ->
        {workflow, runnables} = Workflow.prepare_for_dispatch(strat.workflow)

        new =
          Enum.reject(runnables, &Map.has_key?(strat.pending, &1.id))

        {directives, strat} =
          dispatch_with_limit(new, %{strat | workflow: workflow})

        agent = StratState.put(agent, strat)
        {agent, directives}

      true ->
        {agent, []}
    end
  end

  # -- Instruction Handlers ---------------------------------------------------

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_feed_signal, params: params}) do
    handle_feed(agent, params)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_apply_result, params: params}) do
    handle_apply_result(agent, params)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_set_workflow, params: params}) do
    workflow = Map.get(params, :workflow)
    strat = StratState.get(agent)

    strat = %{
      strat
      | workflow: workflow,
        status: :idle,
        pending: %{},
        queued: [],
        ran_nodes: MapSet.new(),
        held_runnables: [],
        step_history: []
    }

    {StratState.put(agent, strat), []}
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_step}) do
    handle_step(agent)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_resume}) do
    handle_resume(agent)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_set_mode, params: params}) do
    handle_set_mode(agent, params)
  end

  defp handle_instruction(agent, _instruction) do
    {agent, []}
  end

  # -- Feed Signal -------------------------------------------------------------

  defp handle_feed(agent, params) do
    strat = StratState.get(agent)
    input = Map.get(params, :data, params)

    fact =
      case Map.get(params, :signal) do
        nil -> Fact.new(value: input, ancestry: nil)
        signal -> SignalFact.from_signal(signal)
      end

    workflow = Workflow.plan_eagerly(strat.workflow, fact)
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

    if strat.execution_mode == :step do
      held = strat.held_runnables ++ runnables

      status =
        if runnables != [] || held != [], do: :paused, else: :idle

      strat = %{strat | workflow: workflow, held_runnables: held, status: status}
      agent = StratState.put(agent, strat)
      {agent, []}
    else
      {directives, strat} = dispatch_with_limit(runnables, %{strat | workflow: workflow})

      status =
        cond do
          directives != [] || map_size(strat.pending) > 0 -> :running
          Workflow.is_runnable?(workflow) -> :waiting
          true -> :idle
        end

      agent = StratState.put(agent, %{strat | status: status})
      {agent, directives}
    end
  end

  # -- Apply Result (completed, failed, skipped) -------------------------------

  defp handle_apply_result(agent, params) do
    strat = StratState.get(agent)
    runnable = Map.get(params, :runnable)
    pending = Map.delete(strat.pending, runnable.id)

    ran_nodes = MapSet.put(strat.ran_nodes, runnable.node.hash)

    step_history =
      if strat.execution_mode == :step do
        entry = %{
          step_index: length(strat.step_history),
          node: runnable.node.name,
          action:
            if(match?(%Jido.Runic.ActionNode{}, runnable.node),
              do: runnable.node.action_mod,
              else: nil
            ),
          input: runnable.input_fact.value,
          output:
            if(runnable.status == :completed, do: runnable.result.value, else: nil),
          error: if(runnable.status == :failed, do: runnable.error, else: nil),
          status: runnable.status,
          completed_at: System.monotonic_time(:millisecond)
        }

        [entry | strat.step_history]
      else
        strat.step_history
      end

    workflow = Workflow.apply_runnable(strat.workflow, runnable)

    workflow =
      if runnable.status == :failed do
        error_fact =
          Fact.new(
            value: %{error: runnable.error, node: runnable.node.name, status: :failed},
            ancestry: {runnable.node.hash, runnable.input_fact.hash}
          )

        Workflow.plan_eagerly(workflow, error_fact)
      else
        workflow
      end

    workflow = Workflow.plan_eagerly(workflow)

    {workflow, new_runnables} = Workflow.prepare_for_dispatch(workflow)

    genuinely_new =
      new_runnables
      |> Enum.reject(&Map.has_key?(pending, &1.id))
      |> Enum.reject(fn r -> MapSet.member?(ran_nodes, r.node.hash) end)

    if strat.execution_mode == :step do
      held = strat.held_runnables ++ genuinely_new
      productions = Workflow.raw_productions(workflow)
      all_filtered = genuinely_new == [] && new_runnables != []

      status =
        cond do
          map_size(pending) > 0 ->
            :running

          held != [] ->
            :paused

          Workflow.is_runnable?(workflow) && !all_filtered ->
            :paused

          productions != [] ->
            :success

          true ->
            :failure
        end

      strat = %{
        strat
        | workflow: workflow,
          pending: pending,
          ran_nodes: ran_nodes,
          status: status,
          step_history: step_history,
          held_runnables: held
      }

      agent = StratState.put(agent, strat)

      agent =
        case status do
          :success -> put_in(agent.state[:status], :completed)
          :failure -> put_in(agent.state[:status], :failed)
          _ -> agent
        end

      directives =
        if status == :success do
          productions
          |> Enum.map(fn value ->
            signal = Jido.Signal.new!("runic.workflow.production", value, source: "/runic")
            %Jido.Agent.Directive.Emit{signal: signal}
          end)
        else
          []
        end

      {agent, directives}
    else
      {directives, strat} =
        dispatch_with_limit(genuinely_new, %{
          strat
          | pending: pending,
            workflow: workflow,
            ran_nodes: ran_nodes,
            step_history: step_history
        })

      productions = Workflow.raw_productions(workflow)

      has_pending_work = map_size(strat.pending) > 0 || directives != []
      all_filtered = genuinely_new == [] && new_runnables != []

      status =
        cond do
          has_pending_work ->
            :running

          productions != [] ->
            :success

          Workflow.is_runnable?(workflow) && !all_filtered ->
            :waiting

          true ->
            :failure
        end

      strat = %{strat | workflow: workflow, status: status}
      agent = StratState.put(agent, strat)

      agent =
        case status do
          :success -> put_in(agent.state[:status], :completed)
          :failure -> put_in(agent.state[:status], :failed)
          _ -> agent
        end

      directives =
        if status == :success do
          productions = Workflow.raw_productions(workflow)

          emit_directives =
            Enum.map(productions, fn value ->
              signal = Jido.Signal.new!("runic.workflow.production", value, source: "/runic")
              %Jido.Agent.Directive.Emit{signal: signal}
            end)

          directives ++ emit_directives
        else
          directives
        end

      {agent, directives}
    end
  end

  # -- Step Mode Handlers ------------------------------------------------------

  defp handle_step(agent) do
    strat = StratState.get(agent)

    case strat.held_runnables do
      [] ->
        {agent, []}

      held ->
        {directives, strat} = dispatch_with_limit(held, %{strat | held_runnables: []})

        status =
          if directives != [] || map_size(strat.pending) > 0, do: :running, else: strat.status

        strat = %{strat | status: status}
        agent = StratState.put(agent, strat)
        {agent, directives}
    end
  end

  defp handle_resume(agent) do
    strat = StratState.get(agent)
    held = strat.held_runnables

    {directives, strat} =
      dispatch_with_limit(held, %{strat | execution_mode: :auto, held_runnables: []})

    status =
      cond do
        directives != [] || map_size(strat.pending) > 0 -> :running
        Workflow.is_runnable?(strat.workflow) -> :waiting
        true -> strat.status
      end

    strat = %{strat | status: status}
    agent = StratState.put(agent, strat)
    {agent, directives}
  end

  defp handle_set_mode(agent, params) do
    mode = Map.get(params, :mode)
    strat = StratState.get(agent)
    strat = %{strat | execution_mode: mode}
    agent = StratState.put(agent, strat)
    {agent, []}
  end

  # -- Concurrency Control -----------------------------------------------------

  defp dispatch_with_limit(runnables, state) do
    available =
      if state.max_concurrent == :infinity,
        do: length(runnables),
        else: max(state.max_concurrent - map_size(state.pending), 0)

    {to_dispatch, to_queue} = Enum.split(runnables, available)

    directives = Enum.map(to_dispatch, &build_directive/1)

    pending =
      Enum.reduce(to_dispatch, state.pending, fn r, acc ->
        Map.put(acc, r.id, r)
      end)

    {directives, %{state | pending: pending, queued: state.queued ++ to_queue}}
  end

  defp build_directive(runnable) do
    target =
      case runnable.node do
        %Jido.Runic.ActionNode{executor: {:child, tag}} -> {:child, tag}
        %Jido.Runic.ActionNode{executor: {:child, tag, _spec}} -> {:child, tag}
        _ -> :local
      end

    %ExecuteRunnable{
      runnable_id: runnable.id,
      runnable: runnable,
      target: target
    }
  end
end
