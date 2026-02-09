defimpl Runic.Transmutable, for: Atom do
  @moduledoc """
  Transmutable protocol implementation for atoms.

  When the atom is a Jido Action module (detected via `__action_metadata__/0`),
  it is transmuted into a `Jido.Runic.ActionNode`. This enables the ergonomic:

      Workflow.new()
      |> Workflow.add(MyAction)
      |> Workflow.add(OtherAction, to: :my_action)

  Non-action atoms fall through to the default `Any` behavior (constant step).
  """

  alias Jido.Runic.ActionNode

  def transmute(atom), do: to_workflow(atom)

  def to_workflow(atom) do
    if jido_action?(atom) do
      node = ActionNode.new(atom)

      Runic.Workflow.new(name: node.name)
      |> Runic.Workflow.add(node)
    else
      Runic.Transmutable.Any.to_workflow(atom)
    end
  end

  def to_component(atom) do
    if jido_action?(atom) do
      ActionNode.new(atom)
    else
      Runic.Transmutable.Any.to_component(atom)
    end
  end

  defp jido_action?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and
      function_exported?(mod, :__action_metadata__, 0)
  end
end
