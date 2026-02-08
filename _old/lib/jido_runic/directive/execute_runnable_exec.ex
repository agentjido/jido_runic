defimpl Jido.AgentServer.DirectiveExec, for: JidoRunic.Directive.ExecuteRunnable do
  alias Runic.Workflow.Invokable

  def exec(directive, _input_signal, state) do
    agent_pid = self()
    task_sup = if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor

    case Task.Supervisor.start_child(task_sup, fn ->
           result =
             try do
               Invokable.execute(directive.node, directive.runnable)
             rescue
               e ->
                 {:error, Exception.message(e)}
             catch
               kind, reason ->
                 {:error, "Caught #{kind}: #{inspect(reason)}"}
             end

           signal =
             case result do
               {:ok, executed} ->
                 Jido.Signal.new!("runic.runnable.completed", %{runnable: executed},
                   source: "/runic/executor"
                 )

               {:error, reason} ->
                 Jido.Signal.new!(
                   "runic.runnable.failed",
                   %{runnable_id: directive.runnable_id, reason: reason},
                   source: "/runic/executor"
                 )

               executed ->
                 Jido.Signal.new!("runic.runnable.completed", %{runnable: executed},
                   source: "/runic/executor"
                 )
             end

           Jido.AgentServer.cast(agent_pid, signal)
         end) do
      {:ok, _pid} ->
        {:async, nil, state}

      {:error, reason} ->
        fail_signal =
          Jido.Signal.new!(
            "runic.runnable.failed",
            %{runnable_id: directive.runnable_id, reason: inspect(reason)},
            source: "/runic/executor"
          )

        Jido.AgentServer.cast(agent_pid, fail_signal)
        {:async, nil, state}
    end
  end
end
