defmodule Jido.Runic.Examples.Branching.Actions.SafeResponse do
  @moduledoc """
  Produce a safe fallback response when the router flags sensitive requests.
  """

  use Jido.Action,
    name: "branching_safe_response",
    description: "Safe fallback branch for sensitive questions",
    schema: [
      question: [type: :string, required: true],
      route: [type: :atom, required: true],
      detail_level: [type: :atom, required: true],
      confidence: [type: :float, required: true],
      reasoning: [type: :string, required: true]
    ]

  @impl true
  def run(%{question: question, route: :safe, confidence: confidence, reasoning: reasoning}, _context) do
    {:ok,
     %{
       branch: :safe,
       branch_result: safe_message(question),
       explanation: reasoning,
       route_confidence: confidence
     }}
  end

  def run(%{route: route}, _context) do
    {:error, {:invalid_branch_input, {:expected_safe_route, route}}}
  end

  defp safe_message(question) do
    """
    I routed this question to the safe path:
    "#{question}"

    I can still help by:
    - clarifying goals and constraints
    - providing high-level educational context
    - suggesting reputable professional resources
    """
  end
end
