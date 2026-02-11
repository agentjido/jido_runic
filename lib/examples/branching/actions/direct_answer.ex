defmodule Jido.Runic.Examples.Branching.Actions.DirectAnswer do
  @moduledoc """
  Generate a concise answer for questions routed to the direct path.
  """

  use Jido.Action,
    name: "branching_direct_answer",
    description: "Fast direct-answer branch",
    schema: [
      question: [type: :string, required: true],
      route: [type: :atom, required: true],
      detail_level: [type: :atom, required: true],
      confidence: [type: :float, required: true],
      reasoning: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @impl true
  def run(
        %{question: question, route: :direct, detail_level: detail_level, confidence: confidence, reasoning: reasoning},
        _context
      ) do
    prompt = """
    You are a concise technical assistant.
    Answer the question below in markdown.

    Question: "#{question}"

    Requirements:
    - Start with a one-sentence direct answer.
    - Provide 2-4 bullet points.
    - Keep it #{detail_instruction(detail_level)}.
    """

    case Helpers.llm_call(prompt, model: :fast, temperature: 0.3, max_tokens: 380) do
      {:ok, text} ->
        {:ok,
         %{
           branch: :direct,
           branch_result: text,
           explanation: reasoning,
           route_confidence: confidence
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(%{route: route}, _context) do
    {:error, {:invalid_branch_input, {:expected_direct_route, route}}}
  end

  defp detail_instruction(:detailed), do: "detailed but focused"
  defp detail_instruction(_), do: "short and crisp"
end
