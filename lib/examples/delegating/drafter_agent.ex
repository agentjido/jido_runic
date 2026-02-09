defmodule Jido.Runic.Examples.Delegating.DrafterAgent do
  @moduledoc """
  Child agent specialized for article drafting.

  A plain Jido agent (not a Runic agent) that receives work from the
  delegating orchestrator, executes the DraftArticle action via a Runnable,
  and returns the result to the parent.
  """

  use Jido.Agent,
    name: "drafter",
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
