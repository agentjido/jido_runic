defmodule Jido.Runic.Examples.Delegating.EditorAgent do
  @moduledoc """
  Child agent specialized for article editing.

  A plain Jido agent (not a Runic agent) that receives work from the
  delegating orchestrator, executes the EditAndAssemble action via a Runnable,
  and returns the result to the parent.
  """

  use Jido.Agent,
    name: "editor",
    schema: [
      status: [type: :atom, default: :idle]
    ]

  alias Jido.Runic.Examples.Delegating.ExecuteRunnableAction

  def signal_routes(_ctx) do
    [
      {"runic.child.execute", ExecuteRunnableAction}
    ]
  end
end
