defmodule Jido.Runic.Examples.Branching.Actions.AnalysisAnswer do
  @moduledoc """
  Produce a deeper synthesized answer from an analysis plan.
  """

  use Jido.Action,
    name: "branching_analysis_answer",
    description: "Synthesizes a deep answer from planned analysis",
    schema: [
      question: [type: :string, required: true],
      route: [type: :atom, required: true],
      detail_level: [type: :atom, required: true],
      confidence: [type: :float, required: true],
      reasoning: [type: :string, required: true],
      analysis_plan: [type: :any, required: true],
      key_risks: [type: :any, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @impl true
  def run(
        %{
          question: question,
          route: :analysis,
          detail_level: detail_level,
          confidence: confidence,
          reasoning: reasoning,
          analysis_plan: analysis_plan,
          key_risks: key_risks
        },
        _context
      ) do
    plan_text = bullets(analysis_plan)
    risks_text = bullets(key_risks)

    prompt = """
    You are a senior architect.
    Use the analysis plan and risks to answer this question:

    Question: "#{question}"

    Analysis plan:
    #{plan_text}

    Risks/constraints:
    #{risks_text}

    Write a #{answer_style(detail_level)} answer in markdown with:
    - Recommended approach
    - Tradeoffs
    - 2-4 concrete next steps
    """

    case Helpers.llm_call(prompt, model: :capable, temperature: 0.5, max_tokens: 900) do
      {:ok, text} ->
        {:ok,
         %{
           branch: :analysis,
           branch_result: text,
           explanation: reasoning,
           route_confidence: confidence,
           analysis_plan: List.wrap(analysis_plan),
           key_risks: List.wrap(key_risks)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(%{route: route}, _context) do
    {:error, {:invalid_branch_input, {:expected_analysis_route, route}}}
  end

  defp answer_style(:detailed), do: "detailed"
  defp answer_style(_), do: "compact but concrete"

  defp bullets(values) do
    values
    |> List.wrap()
    |> Enum.map_join("\n", fn value -> "- #{value}" end)
  end
end
