defmodule JidoRunic.Strategy do
  @moduledoc """
  A Jido execution strategy powered by a Runic Workflow DAG.

  Incoming signals are converted to Runic Facts and fed into a workflow.
  Runnables are emitted as ExecuteRunnable directives for the runtime.
  Completed runnables are applied back, advancing the workflow until satisfied.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Runic.Workflow.Invokable
  alias JidoRunic.SignalFact
  alias Jido.Agent.Directive.Emit
  alias JidoRunic.Directive.ExecuteRunnable

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
      doc: "Apply a completed runnable result to the workflow",
      name: "runic.apply_result"
    },
    :runic_handle_failure => %{
      schema:
        Zoi.object(%{
          runnable_id: Zoi.integer(),
          reason: Zoi.any()
        }),
      doc: "Handle a failed runnable",
      name: "runic.handle_failure"
    },
    :runic_set_workflow => %{
      schema: Zoi.object(%{workflow: Zoi.any()}),
      doc: "Set the active workflow",
      name: "runic.set_workflow"
    }
  }

  @impl true
  def action_spec(action), do: Map.get(@action_specs, action)

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
        pending_runnables: %{}
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

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_feed_signal, params: params}) do
    feed_signal(agent, params)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_apply_result, params: params}) do
    apply_result(agent, params)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_handle_failure, params: params}) do
    handle_failure(agent, params)
  end

  defp handle_instruction(agent, %Jido.Instruction{action: :runic_set_workflow, params: params}) do
    workflow = Map.get(params, :workflow)
    strat = StratState.get(agent)

    {StratState.put(agent, %{strat | workflow: workflow}), []}
  end

  defp handle_instruction(agent, _instruction) do
    {agent, []}
  end

  defp feed_signal(agent, params) do
    strat = StratState.get(agent)
    workflow = strat.workflow

    input = Map.get(params, :data, params)

    fact =
      case Map.get(params, :signal) do
        nil -> Runic.Workflow.Fact.new(value: input, ancestry: nil)
        signal -> SignalFact.from_signal(signal)
      end

    workflow = Workflow.plan_eagerly(workflow, fact)

    {workflow, directives} = dispatch_runnables(workflow)

    status = if directives == [], do: :idle, else: :running

    pending =
      Enum.reduce(directives, strat.pending_runnables, fn d, acc ->
        Map.put(acc, d.runnable_id, d.runnable)
      end)

    agent =
      StratState.put(agent, %{strat | workflow: workflow, status: status, pending_runnables: pending})

    {agent, directives}
  end

  defp apply_result(agent, params) do
    strat = StratState.get(agent)
    workflow = strat.workflow

    runnable = Map.get(params, :runnable)
    pending = Map.delete(strat.pending_runnables, runnable.id)

    if runnable.status == :failed do
      error_signal =
        Jido.Signal.new!("runic.runnable.failed", %{
          error: runnable.error,
          node: inspect(runnable.node),
          runnable_id: runnable.id
        }, source: "/runic")

      status = if map_size(pending) == 0, do: :failed, else: :running

      agent =
        StratState.put(agent, %{
          strat
          | workflow: workflow,
            status: status,
            pending_runnables: pending
        })

      agent =
        if status == :failed do
          %{agent | state: agent.state |> Map.put(:status, :failed) |> Map.put(:error, runnable.error)}
        else
          agent
        end

      {agent, [%Emit{signal: error_signal}]}
    else
      workflow = Workflow.apply_runnable(workflow, runnable)

      if Workflow.is_runnable?(workflow) do
      {workflow, directives} = dispatch_runnables(workflow)

      pending =
        Enum.reduce(directives, pending, fn d, acc ->
          Map.put(acc, d.runnable_id, d.runnable)
        end)

      status = if directives == [] and map_size(pending) == 0, do: :idle, else: :running

      agent =
        StratState.put(agent, %{
          strat
          | workflow: workflow,
            status: status,
            pending_runnables: pending
        })

      {agent, directives}
    else
      productions = Workflow.raw_productions(workflow)

      emit_directives =
        Enum.map(productions, fn value ->
          signal = Jido.Signal.new!("runic.workflow.production", value, source: "/runic")
          %Jido.Agent.Directive.Emit{signal: signal}
        end)

      agent =
        StratState.put(agent, %{
          strat
          | workflow: workflow,
            status: :satisfied,
            pending_runnables: %{}
        })

      agent = %{agent | state: agent.state |> Map.put(:status, :completed) |> Map.put(:last_answer, productions)}

      {agent, emit_directives}
    end
    end
  end

  defp handle_failure(agent, params) do
    strat = StratState.get(agent)
    runnable_id = Map.get(params, :runnable_id)
    reason = Map.get(params, :reason)

    pending = Map.delete(strat.pending_runnables, runnable_id)

    error_signal =
      Jido.Signal.new!("runic.runnable.failed", %{
        error: reason,
        runnable_id: runnable_id
      }, source: "/runic")

    status = if map_size(pending) == 0, do: :failed, else: :running

    agent =
      StratState.put(agent, %{
        strat
        | status: status,
          pending_runnables: pending
      })

    agent =
      if status == :failed do
        %{agent | state: agent.state |> Map.put(:status, :failed) |> Map.put(:error, reason)}
      else
        agent
      end

    {agent, [%Emit{signal: error_signal}]}
  end

  defp dispatch_runnables(workflow) do
    case Workflow.prepare_for_dispatch(workflow) do
      {updated_workflow, runnables} when is_list(runnables) and runnables != [] ->
        directives =
          Enum.map(runnables, fn runnable ->
            %ExecuteRunnable{
              runnable_id: runnable.id,
              node: runnable.node,
              runnable: runnable
            }
          end)

        {updated_workflow, directives}

      {updated_workflow, _} ->
        {updated_workflow, []}
    end
  end

  @impl true
  def snapshot(agent, _ctx) do
    strat = StratState.get(agent, %{})
    status = Map.get(strat, :status, :idle)

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status == :satisfied,
      result: nil,
      details: %{
        pending_count: map_size(Map.get(strat, :pending_runnables, %{}))
      }
    }
  end

  @impl true
  def tick(agent, _ctx) do
    strat = StratState.get(agent, nil)

    case strat do
      %{status: :running, workflow: workflow} ->
        if Workflow.is_runnable?(workflow) do
          {workflow, directives} = dispatch_runnables(workflow)

          new_directives =
            Enum.reject(directives, fn d ->
              Map.has_key?(strat.pending_runnables, d.runnable_id)
            end)

          pending =
            Enum.reduce(new_directives, strat.pending_runnables, fn d, acc ->
              Map.put(acc, d.runnable_id, d.runnable)
            end)

          agent =
            StratState.put(agent, %{strat | workflow: workflow, pending_runnables: pending})

          {agent, new_directives}
        else
          {agent, []}
        end

      _ ->
        {agent, []}
    end
  end

  @impl true
  def signal_routes(_ctx) do
    [
      {"runic.feed", {:strategy_cmd, :runic_feed_signal}},
      {"runic.runnable.completed", {:strategy_cmd, :runic_apply_result}},
      {"runic.runnable.failed", {:strategy_cmd, :runic_handle_failure}},
      {"runic.set_workflow", {:strategy_cmd, :runic_set_workflow}}
    ]
  end

  @doc "Route a signal to the appropriate instruction atom based on signal type prefix matching."
  @spec route_signal(map(), list()) :: atom() | nil
  def route_signal(signal, routes \\ signal_routes(%{})) do
    type = Map.get(signal, :type, "")

    Enum.find_value(routes, fn {pattern, target} ->
      if String.starts_with?(type, pattern) do
        case target do
          {:strategy_cmd, action} -> action
          _ -> target
        end
      end
    end)
  end

  @doc """
  Execute a runnable directly and return the completed runnable.
  Useful for local execution (no child agent dispatch).
  """
  def execute_runnable(%ExecuteRunnable{node: node, runnable: runnable}) do
    Invokable.execute(node, runnable)
  end
end
