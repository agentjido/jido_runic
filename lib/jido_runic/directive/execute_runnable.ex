defmodule JidoRunic.Directive.ExecuteRunnable do
  @moduledoc """
  A Jido directive that schedules execution of a Runic Runnable.

  The runtime interprets this directive by running the runnable
  and sending the result back to the agent as a completion signal.
  """

  defstruct [:runnable_id, :node, :runnable, :executor_tag]

  @type t :: %__MODULE__{
          runnable_id: integer(),
          node: struct(),
          runnable: Runic.Workflow.Runnable.t(),
          executor_tag: atom() | nil
        }
end
