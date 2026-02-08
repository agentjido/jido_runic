defmodule Jido.Runic.Examples.Studio.Actions.SimulateSearch do
  @moduledoc "Simulate web research by asking the LLM to generate a research summary."

  use Jido.Action,
    name: "studio_simulate_search",
    description: "Simulates web search by generating research findings via LLM",
    schema: [
      topic: [type: :string, required: true],
      queries: [type: :any, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @impl true
  def run(%{topic: topic, queries: queries}, _context) do
    queries_text = Enum.join(List.wrap(queries), "\n- ")

    prompt = """
    You are a research assistant. For the topic "#{topic}", pretend you have searched the web
    using the following queries and found relevant sources:

    - #{queries_text}

    Produce a detailed research summary (3-5 paragraphs) covering key findings, statistics,
    expert opinions, and notable examples. Include fictional but realistic source attributions.
    """

    case Helpers.llm_call(prompt) do
      {:ok, text} -> {:ok, %{topic: topic, research_summary: text}}
      {:error, reason} -> {:error, reason}
    end
  end
end
