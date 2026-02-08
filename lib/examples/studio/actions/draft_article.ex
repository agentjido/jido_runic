defmodule Jido.Runic.Examples.Studio.Actions.DraftArticle do
  @moduledoc "Draft a full article from an outline."

  use Jido.Action,
    name: "studio_draft_article",
    description: "Drafts the full article from an outline",
    schema: [
      topic: [type: :string, required: true],
      outline: [type: :any, required: true]
    ]

  alias Jido.Runic.Examples.Studio.Actions.Helpers

  @impl true
  def run(%{topic: topic, outline: outline}, _context) do
    outline_text = Enum.join(List.wrap(outline), "\n")

    prompt = """
    You are a technical writer. Write a complete article about "#{topic}" following this outline:

    #{outline_text}

    Write 2-3 paragraphs per section. Use a clear, informative tone. Include citations
    where appropriate as [Source: description].
    """

    case Helpers.llm_call(prompt) do
      {:ok, text} -> {:ok, %{topic: topic, draft_markdown: text}}
      {:error, reason} -> {:error, reason}
    end
  end
end
