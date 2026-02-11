defmodule Jido.Runic.Examples.Branching.Actions.DecideTruth do
  @moduledoc """
  Ask the LLM for a structured boolean decision on an input statement.
  """

  use Jido.Action,
    name: "branching_decide_truth",
    description: "Returns a structured true/false decision for a statement",
    schema: [
      question: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @output_schema [
    question: [type: :string, required: true],
    is_true: [type: :boolean, required: true],
    confidence: [type: :float, required: true],
    reasoning: [type: :string, required: true]
  ]

  @impl true
  def run(%{question: question}, _context) do
    prompt = """
    You are a binary decision system.
    Decide if the statement below should be treated as true or false.

    Statement: "#{question}"

    Return only a JSON object with these keys:
    - question (string)
    - is_true (boolean)
    - confidence (float from 0.0 to 1.0)
    - reasoning (one short sentence)
    """

    case Helpers.generate_object(prompt, @output_schema, temperature: 0.9, max_tokens: 200) do
      {:ok, object} ->
        {:ok,
         %{
           question: object["question"] || question,
           is_true: normalize_bool(object["is_true"]),
           confidence: normalize_confidence(object["confidence"]),
           reasoning: normalize_reasoning(object["reasoning"])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_bool(value) when is_boolean(value), do: value
  defp normalize_bool(value) when is_binary(value), do: String.downcase(value) in ["true", "yes", "1"]
  defp normalize_bool(value) when is_number(value), do: value > 0
  defp normalize_bool(_), do: false

  defp normalize_confidence(value) when is_integer(value),
    do: value |> Kernel./(1.0) |> clamp_confidence()

  defp normalize_confidence(value) when is_float(value), do: clamp_confidence(value)

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> clamp_confidence(parsed)
      :error -> 0.5
    end
  end

  defp normalize_confidence(_), do: 0.5

  defp clamp_confidence(value), do: min(1.0, max(0.0, value))

  defp normalize_reasoning(value) when is_binary(value) and value != "", do: value
  defp normalize_reasoning(_), do: "No reasoning provided."
end
