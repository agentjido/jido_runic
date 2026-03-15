defmodule Jido.Runic.Examples.Delegating.DrafterAgent do
  @moduledoc """
  Example custom child agent specialized for article drafting.

  Demonstrates how to create a custom child agent with domain-specific
  routing. For most delegation use cases, `Jido.Runic.ChildWorker`
  provides this behavior out of the box.
  """

  use Jido.Agent,
    name: "drafter",
    schema: [
      status: [type: :atom, default: :idle]
    ]

  @doc false
  @spec plugin_specs() :: [Jido.Plugin.Spec.t()]
  def plugin_specs, do: []

  alias Jido.Runic.Examples.Delegating.ExecuteRunnableAction

  def signal_routes(_ctx) do
    [
      {"runic.child.execute", ExecuteRunnableAction}
    ]
  end
end
