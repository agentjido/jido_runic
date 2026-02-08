defmodule Jido.Runic.Examples.Studio.Actions.PlanQueries do
  @moduledoc "Generate search queries and an outline seed from a topic."

  use Jido.Action,
    name: "studio_plan_queries",
    description: "Plans research queries for a topic",
    schema: [
      topic: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @output_schema [
    topic: [type: :string, required: true],
    queries: [type: {:list, :string}, required: true],
    outline_seed: [type: {:list, :string}, required: true]
  ]

  @impl true
  def run(%{topic: topic}, _context) do
    prompt = """
    You are a research planner. Given the topic "#{topic}":
    1. Generate 3 specific search queries that would surface useful information.
    2. Suggest an outline with 3-5 section titles.
    """

    case Helpers.generate_object(prompt, @output_schema) do
      {:ok, object} ->
        {:ok,
         %{
           topic: object["topic"] || topic,
           queries: object["queries"] || [],
           outline_seed: object["outline_seed"] || []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
