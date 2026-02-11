defmodule Jido.Runic.Examples.Branching.Actions.RouteQuestion do
  @moduledoc """
  Route an incoming question into a workflow branch using structured LLM output.
  """

  use Jido.Action,
    name: "branching_route_question",
    description: "Classifies a question into a routing branch",
    schema: [
      question: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @routes ["direct", "analysis", "safe"]
  @detail_levels ["brief", "detailed"]

  @output_schema [
    question: [type: :string, required: true],
    route: [type: {:in, @routes}, required: true],
    detail_level: [type: {:in, @detail_levels}, required: true],
    confidence: [type: :float, required: true],
    reasoning: [type: :string, required: true]
  ]

  @impl true
  def run(%{question: question}, _context) do
    prompt = """
    You are a workflow router.
    Classify the user question into exactly one route:

    - direct: straightforward factual/explanatory question answerable quickly
    - analysis: design, tradeoff, architecture, strategy, or multi-step reasoning
    - safe: medical/legal/financial or unsafe-sensitive request needing caution

    Also choose detail_level:
    - brief: short concise response is enough
    - detailed: deeper response is needed

    Return only JSON with:
    - question (string)
    - route (direct|analysis|safe)
    - detail_level (brief|detailed)
    - confidence (float 0.0-1.0)
    - reasoning (one short sentence)

    Question: "#{question}"
    """

    case Helpers.generate_object(prompt, @output_schema,
           model: :fast,
           temperature: 0.2,
           max_tokens: 220
         ) do
      {:ok, object} ->
        object = if is_map(object), do: object, else: %{}

        {:ok,
         %{
           question: get_field(object, "question", :question, question),
           route: get_field(object, "route", :route, nil) |> normalize_route(),
           detail_level: get_field(object, "detail_level", :detail_level, nil) |> normalize_detail_level(),
           confidence: get_field(object, "confidence", :confidence, 0.5) |> normalize_confidence(),
           reasoning: get_field(object, "reasoning", :reasoning, nil) |> normalize_reasoning()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_route("direct"), do: :direct
  defp normalize_route("analysis"), do: :analysis
  defp normalize_route("safe"), do: :safe
  defp normalize_route(:direct), do: :direct
  defp normalize_route(:analysis), do: :analysis
  defp normalize_route(:safe), do: :safe
  defp normalize_route(_), do: :analysis

  defp normalize_detail_level("brief"), do: :brief
  defp normalize_detail_level("detailed"), do: :detailed
  defp normalize_detail_level(:brief), do: :brief
  defp normalize_detail_level(:detailed), do: :detailed
  defp normalize_detail_level(_), do: :brief

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
  defp normalize_reasoning(_), do: "No routing rationale provided."

  defp get_field(map, string_key, atom_key, fallback) do
    Map.get(map, string_key, Map.get(map, atom_key, fallback))
  end
end
