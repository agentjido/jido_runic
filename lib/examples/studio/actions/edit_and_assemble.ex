defmodule Jido.Runic.Examples.Studio.Actions.EditAndAssemble do
  @moduledoc "Polish and finalize a draft article into publication-ready markdown."

  use Jido.Action,
    name: "studio_edit_and_assemble",
    description: "Edits and polishes the draft into a final article",
    schema: [
      topic: [type: :string, required: true],
      draft_markdown: [type: :string, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @impl true
  def run(%{topic: topic, draft_markdown: draft_markdown}, _context) do
    prompt = """
    You are an editor. Polish and finalize this draft article about "#{topic}".
    Improve transitions, fix inconsistencies, tighten prose, and ensure a coherent narrative.
    Return the final article in clean Markdown format.

    Draft:
    #{draft_markdown}
    """

    case Helpers.llm_call(prompt) do
      {:ok, text} -> {:ok, %{markdown: text, quality_score: 0.85}}
      {:error, reason} -> {:error, reason}
    end
  end
end
