defmodule Jido.Runic.Examples.Delegating.ExecuteRunnableAction do
  @moduledoc """
  Example custom child action for executing a Runic Runnable.

  Demonstrates how to build a custom child action that wraps
  `Jido.Runic.RunnableExecution` with additional logic. For most cases,
  use `Jido.Runic.ChildWorker` which provides this behavior out of the box.
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
  alias Jido.Runic.RunnableExecution

  @impl true
  def run(%{runnable: runnable, runnable_id: _runnable_id, tag: _tag}, context) do
    executed = RunnableExecution.execute(runnable)
    result_signal = RunnableExecution.completion_signal(executed, source: "/runic/child")

    agent_like = %{state: context.state}
    emit_directive = Directive.emit_to_parent(agent_like, result_signal)

    {:ok, %{}, List.wrap(emit_directive)}
  end
end
