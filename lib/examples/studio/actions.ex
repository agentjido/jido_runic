defmodule JidoRunic.Examples.Studio.Actions do
  @moduledoc """
  Jido Actions for the AI Research Studio pipeline.
  Each action supports mock mode (fixtures) and live mode (LLM API calls).
  """

  defmodule Helpers do
    @moduledoc false

    def mock_mode? do
      Application.get_env(:jido_runic, :studio_mock_mode, true)
    end

    def llm_call(prompt) do
      model = Jido.AI.resolve_model(:fast)
      messages = [%{role: "user", content: prompt}]
      opts = [max_tokens: 1024, temperature: 0.7]

      case ReqLLM.Generation.generate_text(model, messages, opts) do
        {:ok, response} ->
          text = extract_text(response)
          {:ok, %{text: text}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp extract_text(%ReqLLM.Response{} = resp), do: ReqLLM.Response.text(resp)
    defp extract_text(%{"choices" => [%{"message" => %{"content" => c}} | _]}), do: c
    defp extract_text(%{choices: [%{message: %{content: c}} | _]}), do: c
    defp extract_text(%{"content" => [%{"text" => t} | _]}), do: t
    defp extract_text(%{content: [%{text: t} | _]}), do: t
    defp extract_text(%{content: c}) when is_binary(c), do: c
    defp extract_text(%{"content" => c}) when is_binary(c), do: c
    defp extract_text(other), do: inspect(other)

    def extract_json(text) do
      case Regex.run(~r/\{[\s\S]*\}/m, text) do
        [json] -> json
        _ -> text
      end
    end
  end

  defmodule PlanQueries do
    @moduledoc "Generate search queries and outline seed from a topic."
    use Jido.Action,
      name: "studio_plan_queries",
      description: "Plans research queries for a topic",
      schema: [
        topic: [type: :string, required: true],
        audience: [type: :string, default: "general"],
        num_queries: [type: :integer, default: 3]
      ]

    alias JidoRunic.Examples.Studio.Actions.Helpers
    alias JidoRunic.Examples.Studio.Fixtures

    def run(%{topic: topic} = params, _context) do
      if Helpers.mock_mode?() do
        {:ok, Fixtures.query_plan_for(topic)}
      else
        prompt = """
        You are a research planner. Given the topic "#{topic}" for a #{Map.get(params, :audience, "general")} audience:
        1. Generate #{Map.get(params, :num_queries, 3)} specific search queries
        2. Suggest an outline with section titles

        Respond in this exact JSON format:
        {"topic": "...", "queries": ["query1", "query2", "query3"], "outline_seed": ["Section 1", "Section 2", "Section 3"]}
        """

        with {:ok, result} <- Helpers.llm_call(prompt) do
          case Jason.decode(Helpers.extract_json(result.text)) do
            {:ok, decoded} ->
              {:ok,
               %{
                 topic: decoded["topic"] || topic,
                 queries: decoded["queries"] || [],
                 outline_seed: decoded["outline_seed"] || []
               }}

            {:error, _} ->
              {:ok, Fixtures.query_plan_for(topic)}
          end
        end
      end
    end
  end

  defmodule WebSearch do
    @moduledoc "Search the web and retrieve source documents."
    use Jido.Action,
      name: "studio_web_search",
      description: "Searches for and retrieves a source document",
      schema: [
        query: [type: :string, required: true]
      ]

    alias JidoRunic.Examples.Studio.Actions.Helpers
    alias JidoRunic.Examples.Studio.Fixtures

    def run(%{query: query}, _context) do
      if Helpers.mock_mode?() do
        {:ok, Map.from_struct(Fixtures.source_doc_for(query))}
      else
        prompt = """
        Simulate being a search engine. For the query: "#{query}"

        Generate a realistic search result with factual content. Respond in this exact JSON format:
        {"url": "https://example.com/article", "title": "Article Title", "content": "Detailed factual content about the topic, at least 3-4 sentences.", "snippet": "Brief summary"}
        """

        with {:ok, result} <- Helpers.llm_call(prompt) do
          case Jason.decode(Helpers.extract_json(result.text)) do
            {:ok, decoded} ->
              {:ok,
               %{
                 url: decoded["url"],
                 title: decoded["title"],
                 content: decoded["content"],
                 snippet: decoded["snippet"],
                 retrieved_at: DateTime.utc_now() |> DateTime.to_iso8601()
               }}

            {:error, _} ->
              {:ok, Map.from_struct(Fixtures.source_doc_for(query))}
          end
        end
      end
    end
  end

  defmodule ExtractClaims do
    @moduledoc "Extract atomic claims from a source document."
    use Jido.Action,
      name: "studio_extract_claims",
      description: "Extracts verifiable claims from a source document",
      schema: [
        content: [type: :string, required: true],
        url: [type: :string, required: true]
      ]

    alias JidoRunic.Examples.Studio.Actions.Helpers
    alias JidoRunic.Examples.Studio.{Fixtures, Schemas}

    def run(%{content: content, url: url}, _context) do
      if Helpers.mock_mode?() do
        doc = %Schemas.SourceDoc{url: url, content: content}
        claims = Fixtures.claims_for(doc) |> Enum.map(&Map.from_struct/1)
        {:ok, %{claims: claims}}
      else
        prompt = """
        Extract 2-3 specific, verifiable claims from this text. For each claim, include a direct quote.

        Text: #{content}
        Source URL: #{url}

        Respond in this exact JSON format:
        {"claims": [{"text": "Claim statement", "quote": "Direct quote from text", "url": "#{url}", "confidence": 0.9, "tags": ["tag1"]}]}
        """

        with {:ok, result} <- Helpers.llm_call(prompt) do
          case Jason.decode(Helpers.extract_json(result.text)) do
            {:ok, %{"claims" => claims}} ->
              {:ok, %{claims: claims}}

            {:error, _} ->
              doc = %Schemas.SourceDoc{url: url, content: content}
              {:ok, %{claims: Fixtures.claims_for(doc) |> Enum.map(&Map.from_struct/1)}}
          end
        end
      end
    end
  end

  defmodule BuildOutline do
    @moduledoc "Build a structured outline from claims."
    use Jido.Action,
      name: "studio_build_outline",
      description: "Builds an article outline from claims",
      schema: [
        topic: [type: :string, required: true],
        claims_summary: [type: :string, default: ""]
      ]

    alias JidoRunic.Examples.Studio.Actions.Helpers
    alias JidoRunic.Examples.Studio.Fixtures

    def run(%{topic: topic} = params, _context) do
      if Helpers.mock_mode?() do
        outline = Fixtures.outline_for(topic, [])

        {:ok,
         %{
           topic: outline.topic,
           sections: Enum.map(outline.sections, &Map.from_struct/1)
         }}
      else
        prompt = """
        Create a 3-section article outline for "#{topic}".
        Available claims summary: #{Map.get(params, :claims_summary, "general")}

        Respond in this exact JSON format:
        {"topic": "#{topic}", "sections": [{"id": "intro", "title": "Introduction", "intent": "...", "required_tags": ["tag1"]}]}
        """

        with {:ok, result} <- Helpers.llm_call(prompt) do
          case Jason.decode(Helpers.extract_json(result.text)) do
            {:ok, decoded} ->
              {:ok,
               %{
                 topic: decoded["topic"] || topic,
                 sections:
                   (decoded["sections"] || [])
                   |> Enum.map(fn s ->
                     %{
                       id: s["id"] || "section",
                       title: s["title"] || "Section",
                       intent: s["intent"] || "",
                       required_tags: s["required_tags"] || []
                     }
                   end)
               }}

            {:error, _} ->
              outline = Fixtures.outline_for(topic, [])

              {:ok,
               %{
                 topic: outline.topic,
                 sections: Enum.map(outline.sections, &Map.from_struct/1)
               }}
          end
        end
      end
    end
  end

  defmodule DraftSection do
    @moduledoc "Draft a single article section."
    use Jido.Action,
      name: "studio_draft_section",
      description: "Drafts a single section of the article",
      schema: [
        section_id: [type: :string, required: true],
        title: [type: :string, required: true],
        intent: [type: :string, default: ""],
        claims_text: [type: :string, default: ""]
      ]

    alias JidoRunic.Examples.Studio.Actions.Helpers
    alias JidoRunic.Examples.Studio.{Fixtures, Schemas}

    def run(params, _context) do
      if Helpers.mock_mode?() do
        section = %Schemas.OutlineSection{
          id: params.section_id,
          title: params.title,
          intent: Map.get(params, :intent, "")
        }

        draft = Fixtures.draft_for(section, [])
        {:ok, Map.from_struct(draft)}
      else
        prompt = """
        Write a section for a research article.
        Section: #{params.title}
        Intent: #{Map.get(params, :intent, "")}
        Supporting evidence: #{Map.get(params, :claims_text, "general knowledge")}

        Write 2-3 paragraphs with citations noted as [Source: URL].
        """

        with {:ok, result} <- Helpers.llm_call(prompt) do
          {:ok,
           %{
             section_id: params.section_id,
             title: params.title,
             markdown: "## #{params.title}\n\n#{result.text}",
             citations: [],
             used_claim_hashes: []
           }}
        end
      end
    end
  end

  defmodule EditAndAssemble do
    @moduledoc "Edit and assemble all section drafts into a final article."
    use Jido.Action,
      name: "studio_edit_and_assemble",
      description: "Edits and assembles drafts into a final article",
      schema: [
        drafts_text: [type: :string, required: true],
        topic: [type: :string, default: ""]
      ]

    alias JidoRunic.Examples.Studio.Actions.Helpers

    def run(params, _context) do
      if Helpers.mock_mode?() do
        {:ok,
         %{
           markdown:
             "# #{Map.get(params, :topic, "Research Article")}\n\n#{params.drafts_text}",
           quality_score: 0.85,
           citations: [],
           sections: []
         }}
      else
        prompt = """
        You are an editor. Polish and assemble this draft article about "#{Map.get(params, :topic, "")}".
        Improve transitions, fix inconsistencies, and ensure a coherent narrative.

        Draft content:
        #{params.drafts_text}

        Return the polished article in Markdown format.
        """

        with {:ok, result} <- Helpers.llm_call(prompt) do
          {:ok,
           %{
             markdown: result.text,
             quality_score: 0.85,
             citations: [],
             sections: []
           }}
        end
      end
    end
  end
end
