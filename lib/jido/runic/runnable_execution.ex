defmodule Jido.Runic.RunnableExecution do
  @moduledoc """
  Shared execution logic for Runic Runnables.

  Provides the canonical pipeline for executing a Runnable and building
  the corresponding completion signal. Used by both local directive execution
  and child agent workers to ensure consistent error handling and signal
  construction.

  ## Usage

  For framework-level execution (directives, workers):

      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed)

  For custom child agents that need to add logic around execution:

      executed = RunnableExecution.execute(runnable)
      # ... custom post-processing ...
      signal = RunnableExecution.completion_signal(executed, source: "/my/custom/agent")
  """

  alias Runic.Workflow.{Invokable, Runnable}

  @doc """
  Execute a Runnable with standardized error handling.

  Calls `Invokable.execute/2` within a try/rescue/catch block,
  converting any exception or throw into a failed Runnable.
  """
  @spec execute(Runnable.t()) :: Runnable.t()
  def execute(%Runnable{} = runnable) do
    try do
      Invokable.execute(runnable.node, runnable)
    rescue
      e ->
        Runnable.fail(runnable, Exception.message(e))
    catch
      kind, reason ->
        Runnable.fail(runnable, "Caught #{kind}: #{inspect(reason)}")
    end
  end

  @doc """
  Build a completion signal from an executed Runnable.

  Maps the runnable status to the appropriate signal type:
  - `:completed` → `"runic.runnable.completed"`
  - `:failed` → `"runic.runnable.failed"`
  - `:skipped` → `"runic.runnable.completed"`

  ## Options

  - `:source` - Signal source path. Defaults to `"/runic/executor"`.
  """
  @spec completion_signal(Runnable.t(), keyword()) :: Jido.Signal.t()
  def completion_signal(%Runnable{} = executed, opts \\ []) do
    source = Keyword.get(opts, :source, "/runic/executor")

    signal_type =
      case executed.status do
        :completed -> "runic.runnable.completed"
        :failed -> "runic.runnable.failed"
        :skipped -> "runic.runnable.completed"
      end

    Jido.Signal.new!(signal_type, %{runnable: executed}, source: source)
  end
end
