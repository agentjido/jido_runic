defmodule Jido.Runic.ChildWorker do
  @moduledoc """
  Default child agent for delegated Runic workflow execution.

  A minimal Jido agent that receives Runnables from a parent orchestrator,
  executes them, and returns results. Use this as the default `child_modules`
  entry when child agents don't need custom domain logic.

  ## Usage

      use Jido.Agent,
        strategy: {Jido.Runic.Strategy,
          child_modules: %{
            drafter: Jido.Runic.ChildWorker,
            editor:  Jido.Runic.ChildWorker
          }}

  For custom child agents that need domain-specific behavior, create your
  own agent module and use `Jido.Runic.RunnableExecution` as a building
  block for execution logic.
  """

  use Jido.Agent,
    name: "runic_child_worker",
    schema: [
      status: [type: :atom, default: :idle]
    ]

  @doc false
  def signal_routes(_ctx) do
    [
      {"runic.child.execute", __MODULE__.ExecuteAction}
    ]
  end
end

defmodule Jido.Runic.ChildWorker.ExecuteAction do
  @moduledoc """
  Jido Action that executes a Runic Runnable and returns the result to the parent.

  Used by `Jido.Runic.ChildWorker` and available as a building block for custom
  child agents. Handles execution, error wrapping, and parent signaling.
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
  def run(%{runnable: runnable, runnable_id: runnable_id, tag: _tag}, context) do
    if runnable.id != runnable_id do
      {:error, "Runnable ID mismatch: expected #{inspect(runnable_id)}, got #{inspect(runnable.id)}"}
    else
      executed = RunnableExecution.execute(runnable)
      result_signal = RunnableExecution.completion_signal(executed, source: "/runic/child")

      agent_like = %{state: context.state}
      emit_directive = Directive.emit_to_parent(agent_like, result_signal)

      {:ok, %{}, List.wrap(emit_directive)}
    end
  end
end
