defimpl Jido.AgentServer.DirectiveExec, for: Jido.Runic.Directive.ExecuteRunnable do
  alias Runic.Workflow.{Invokable, Runnable}

  def exec(%{runnable: runnable, target: :local} = _directive, _input_signal, state) do
    agent_pid = self()

    task_sup =
      if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor

    Task.Supervisor.start_child(task_sup, fn ->
      executed =
        try do
          Invokable.execute(runnable.node, runnable)
        rescue
          e ->
            Runnable.fail(runnable, Exception.message(e))
        catch
          kind, reason ->
            Runnable.fail(runnable, "Caught #{kind}: #{inspect(reason)}")
        end

      signal_type =
        case executed.status do
          :completed -> "runic.runnable.completed"
          :failed -> "runic.runnable.failed"
          :skipped -> "runic.runnable.completed"
        end

      signal =
        Jido.Signal.new!(
          signal_type,
          %{runnable: executed},
          source: "/runic/executor"
        )

      Jido.AgentServer.cast(agent_pid, signal)
    end)

    {:async, nil, state}
  end

  def exec(%{target: nil} = directive, input_signal, state) do
    exec(%{directive | target: :local}, input_signal, state)
  end
end
