defmodule Jido.Runic.Examples.Studio.Actions.BuildOutline do
  @moduledoc "Build a structured article outline from research findings."

  use Jido.Action,
    name: "studio_build_outline",
    description: "Builds an article outline from research summary",
    schema: [
      topic: [type: :string, required: true],
      research_summary: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @output_schema [
    topic: [type: :string, required: true],
    outline: [type: {:list, :string}, required: true]
  ]

  @impl true
  def run(%{topic: topic, research_summary: research_summary}, _context) do
    prompt = """
    You are a content strategist. Given the topic "#{topic}" and the following research summary,
    create a detailed article outline with a title and 3-5 section headings in markdown format.

    Research:
    #{research_summary}
    """

    case Helpers.generate_object(prompt, @output_schema) do
      {:ok, object} ->
        {:ok,
         %{
           topic: object["topic"] || topic,
           outline: object["outline"] || []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
