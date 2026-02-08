defmodule JidoRunic.Examples.Studio.BatchActions do
  @moduledoc """
  Batch adapter actions that reshape data between Studio pipeline stages.
  Each wraps existing single-item actions to handle fan-out/collection internally,
  enabling a linear Runic DAG where each node's output matches the next node's input.
  """

  defmodule WebSearchBatch do
    @moduledoc """
    Fan-out: runs WebSearch for each query, collects results into a sources list.

    Input:  %{queries: [string], topic: string}
    Output: %{sources: [source_map], topic: string}
    """
    use Jido.Action,
      name: "studio_web_search_batch",
      description: "Searches the web for each query and collects source documents",
      schema: [
        topic: [type: :string, required: true],
        queries: [type: :any, required: true]
      ]

    alias JidoRunic.Examples.Studio.Actions

    def run(%{queries: queries, topic: topic}, context) do
      sources =
        Enum.flat_map(queries, fn query ->
          case Actions.WebSearch.run(%{query: query}, context) do
            {:ok, source} -> [source]
            {:error, _} -> []
          end
        end)

      {:ok, %{sources: sources, topic: topic}}
    end
  end

  defmodule ExtractClaimsBatch do
    @moduledoc """
    Fan-out: runs ExtractClaims for each source, collects and flattens all claims.

    Input:  %{sources: [source_map], topic: string}
    Output: %{claims: [claim_map], claims_summary: string, topic: string}
    """
    use Jido.Action,
      name: "studio_extract_claims_batch",
      description: "Extracts claims from each source document and produces a summary",
      schema: [
        topic: [type: :string, required: true],
        sources: [type: :any, required: true]
      ]

    alias JidoRunic.Examples.Studio.Actions

    def run(%{sources: sources, topic: topic}, context) do
      claims =
        Enum.flat_map(sources, fn source ->
          params = %{
            content: Map.get(source, :content) || Map.get(source, "content", ""),
            url: Map.get(source, :url) || Map.get(source, "url", "")
          }

          case Actions.ExtractClaims.run(params, context) do
            {:ok, %{claims: extracted}} -> extracted
            {:error, _} -> []
          end
        end)

      claims_summary =
        claims
        |> Enum.map(fn c -> Map.get(c, :text) || Map.get(c, "text", "") end)
        |> Enum.join("; ")

      {:ok, %{claims: claims, claims_summary: claims_summary, topic: topic}}
    end
  end

  defmodule DraftSectionsBatch do
    @moduledoc """
    Fan-out: runs DraftSection for each section, concatenates all drafts.

    Input:  %{sections: [section_map], topic: string}
    Output: %{drafts_text: string, topic: string}

    Does not require claims_summary — uses each section's title and intent for drafting.
    """
    use Jido.Action,
      name: "studio_draft_sections_batch",
      description: "Drafts each section and assembles them into a single text",
      schema: [
        topic: [type: :string, required: true],
        sections: [type: :any, required: true],
        claims_summary: [type: :string, default: ""]
      ]

    alias JidoRunic.Examples.Studio.Actions

    def run(%{sections: sections, topic: topic} = params, context) do
      claims_summary = Map.get(params, :claims_summary, "")

      drafts =
        Enum.map(sections, fn section ->
          draft_params = %{
            section_id: Map.get(section, :id) || Map.get(section, "id", "unknown"),
            title: Map.get(section, :title) || Map.get(section, "title", "Untitled"),
            intent: Map.get(section, :intent) || Map.get(section, "intent", ""),
            claims_text: claims_summary
          }

          case Actions.DraftSection.run(draft_params, context) do
            {:ok, draft} ->
              Map.get(draft, :markdown) || Map.get(draft, "markdown", "")

            {:error, _} ->
              ""
          end
        end)

      drafts_text = Enum.join(drafts, "\n\n---\n\n")

      {:ok, %{drafts_text: drafts_text, topic: topic}}
    end
  end
end
