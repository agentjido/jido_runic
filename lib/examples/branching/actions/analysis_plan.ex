defmodule Jido.Runic.Examples.Branching.Actions.AnalysisPlan do
  @moduledoc """
  Build a structured analysis plan for questions routed to deeper reasoning.
  """

  use Jido.Action,
    name: "branching_analysis_plan",
    description: "Generates a structured analysis plan",
    schema: [
      question: [type: :string, required: true],
      route: [type: :atom, required: true],
      detail_level: [type: :atom, required: true],
      confidence: [type: :float, required: true],
      reasoning: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @output_schema [
    question: [type: :string, required: true],
    analysis_plan: [type: {:list, :string}, required: true],
    key_risks: [type: {:list, :string}, required: true]
  ]

  @impl true
  def run(
        %{
          question: question,
          route: :analysis,
          detail_level: detail_level,
          confidence: confidence,
          reasoning: reasoning
        },
        _context
      ) do
    prompt = """
    You are a systems-thinking planner.
    Build a practical analysis plan for this question:
    "#{question}"

    Return JSON:
    - question
    - analysis_plan (3-6 steps)
    - key_risks (2-4 key risks or constraints)

    Keep the plan #{plan_style(detail_level)}.
    """

    case Helpers.generate_object(prompt, @output_schema,
           model: :fast,
           temperature: 0.4,
           max_tokens: 320
         ) do
      {:ok, object} ->
        object = if is_map(object), do: object, else: %{}

        analysis_plan =
          object
          |> get_field("analysis_plan", :analysis_plan, [])
          |> normalize_list()
          |> with_fallback_plan(question, detail_level)

        key_risks =
          object
          |> get_field("key_risks", :key_risks, [])
          |> normalize_list()
          |> with_fallback_risks()

        {:ok,
         %{
           question: get_field(object, "question", :question, question),
           route: :analysis,
           detail_level: detail_level,
           confidence: confidence,
           reasoning: reasoning,
           analysis_plan: analysis_plan,
           key_risks: key_risks
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(%{route: route}, _context) do
    {:error, {:invalid_branch_input, {:expected_analysis_route, route}}}
  end

  defp plan_style(:detailed), do: "detailed and explicit"
  defp plan_style(_), do: "lean and concise"

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(value) when is_binary(value), do: [value]
  defp normalize_list(_), do: []

  defp with_fallback_plan([], question, :detailed) do
    [
      "Break down scope and business goals for: #{question}",
      "Map domain boundaries and coupling points in current system",
      "Define migration phases with rollout and rollback strategy",
      "Select communication/data consistency patterns across services",
      "Specify observability, SLOs, and success criteria"
    ]
  end

  defp with_fallback_plan([], question, _detail_level) do
    [
      "Clarify migration goals for: #{question}",
      "Define initial service boundaries and data ownership",
      "Plan phased rollout with measurable checkpoints"
    ]
  end

  defp with_fallback_plan(plan, _question, _detail_level), do: plan

  defp with_fallback_risks([]) do
    [
      "Data consistency during split transactions",
      "Operational complexity from distributed deployments",
      "Latency and reliability issues between services"
    ]
  end

  defp with_fallback_risks(risks), do: risks

  defp get_field(map, string_key, atom_key, fallback) do
    Map.get(map, string_key, Map.get(map, atom_key, fallback))
  end
end
