defmodule Jido.Runic.Examples.Delegating.ExecuteRunnableAction do
  @moduledoc """
  Jido Action that executes a Runic Runnable and returns the result to the parent.

  Used by child agents in a delegating orchestrator pattern. The child receives
  a `"runic.child.execute"` signal containing a Runnable, executes it locally,
  and emits the result back to the parent via `emit_to_parent`.
  """

  use Jido.Action,
    name: "execute_runnable",
    description: "Execute a Runic Runnable and emit result to parent",
    schema: [
      runnable: [type: :any, required: true],
      runnable_id: [type: :any, required: true],
      tag: [type: :any, required: true]
    ]

  alias Jido.Agent.Directive
  alias Runic.Workflow.{Invokable, Runnable}

  @impl true
  def run(%{runnable: runnable, runnable_id: _runnable_id, tag: _tag}, context) do
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

    result_signal =
      Jido.Signal.new!(
        signal_type,
        %{runnable: executed},
        source: "/runic/child"
      )

    agent_like = %{state: context.state}
    emit_directive = Directive.emit_to_parent(agent_like, result_signal)

    {:ok, %{}, List.wrap(emit_directive)}
  end
end
