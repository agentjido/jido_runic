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
    result =
      try do
        Invokable.execute(runnable.node, runnable)
      rescue
        e ->
          Runnable.fail(runnable, format_exception(runnable, e, __STACKTRACE__))
      catch
        kind, reason ->
          Runnable.fail(runnable, format_throw(runnable, kind, reason))
      end

    maybe_telemetry(result)
    result
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

  defp format_exception(runnable, exception, stacktrace) do
    node_label = runnable.node.name || runnable.node.hash || "unknown_node"
    "[#{node_label}] " <> Exception.format(:error, exception, stacktrace)
  end

  defp format_throw(runnable, kind, reason) do
    node_label = runnable.node.name || runnable.node.hash || "unknown_node"
    "[#{node_label}] Caught #{kind}: #{inspect(reason)}"
  end

  defp maybe_telemetry(%Runnable{} = runnable) do
    measurements = %{status: runnable.status}
    metadata = %{node: runnable.node, runnable_id: runnable.id}

    :telemetry.execute([:jido_runic, :runnable, runnable.status], measurements, metadata)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
