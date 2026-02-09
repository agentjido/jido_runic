defimpl Jido.AgentServer.DirectiveExec, for: Jido.Runic.Directive.ExecuteRunnable do
  alias Jido.Runic.RunnableExecution

  def exec(%{runnable: runnable, target: :local} = _directive, _input_signal, state) do
    agent_pid = self()

    task_sup =
      if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor

    Task.Supervisor.start_child(task_sup, fn ->
      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed)

      Jido.AgentServer.cast(agent_pid, signal)
    end)

    {:async, nil, state}
  end

  def exec(%{target: {:child, tag}} = directive, _input_signal, state) do
    agent_pid = self()

    signal =
      Jido.Signal.new!(
        "runic.child.dispatch",
        %{
          tag: tag,
          runnable_id: directive.runnable_id,
          runnable: directive.runnable,
          executor: directive.runnable.node.executor
        },
        source: "/runic/executor"
      )

    Jido.AgentServer.cast(agent_pid, signal)

    {:async, nil, state}
  end

  def exec(%{target: nil} = directive, input_signal, state) do
    exec(%{directive | target: :local}, input_signal, state)
  end
end
