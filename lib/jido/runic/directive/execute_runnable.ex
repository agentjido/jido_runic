defmodule Jido.Runic.Directive.ExecuteRunnable do
  @moduledoc """
  Execute a Runic Runnable via the Jido runtime.

  The strategy builds this from each runnable returned by
  `Workflow.prepare_for_dispatch/1`. The runtime executes the
  runnable via `Invokable.execute/2` and sends the result back
  as a completion signal.

  The executed Runnable carries Runic runtime events —
  the strategy folds them back into the workflow via
  `Workflow.apply_runnable/2`. No manual graph manipulation needed.
  """

  defstruct [:runnable_id, :runnable, :target]

  @type target :: :local | {:child, atom()} | {:pid, pid()}

  @type t :: %__MODULE__{
          runnable_id: integer(),
          runnable: Runic.Workflow.Runnable.t(),
          target: target()
        }
end
