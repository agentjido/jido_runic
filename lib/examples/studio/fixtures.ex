defmodule JidoRunic.Examples.Studio.Fixtures do
  @moduledoc """
  Mock data fixtures for the AI Research Studio demo.
  Enables running the full pipeline without API keys.
  """

  alias JidoRunic.Examples.Studio.Schemas.{SourceDoc, Claim, Outline, OutlineSection, SectionDraft, Article}

  def query_plan_for(topic) do
    %{
      topic: topic,
      queries: [
        "#{topic} overview introduction",
        "#{topic} key concepts fundamentals",
        "#{topic} practical applications examples"
      ],
      outline_seed: ["Introduction", "Key Concepts", "Applications"]
    }
  end

  def source_doc_for(query) do
    docs = %{
      "overview" => %SourceDoc{
        url: "https://example.com/#{slug(query)}/overview",
        title: "Understanding #{titleize(query)}",
        content: "#{titleize(query)} is a fundamental concept in modern software development. It enables developers to build scalable, fault-tolerant systems. The core principle revolves around lightweight processes that communicate through message passing. Each process maintains its own state and can be supervised for reliability.",
        snippet: "A comprehensive overview of #{titleize(query)}",
        retrieved_at: DateTime.utc_now()
      },
      "concepts" => %SourceDoc{
        url: "https://example.com/#{slug(query)}/concepts",
        title: "Core Concepts of #{titleize(query)}",
        content: "The key concepts include: immutability, pattern matching, recursion, and the actor model. Immutability ensures data cannot be changed after creation, eliminating entire classes of bugs. Pattern matching provides elegant control flow. The actor model treats each unit of computation as an independent entity.",
        snippet: "Deep dive into core concepts",
        retrieved_at: DateTime.utc_now()
      },
      "applications" => %SourceDoc{
        url: "https://example.com/#{slug(query)}/applications",
        title: "Real-World Applications of #{titleize(query)}",
        content: "In practice, these concepts are applied in web servers, real-time communication systems, IoT platforms, and distributed databases. Companies like WhatsApp and Discord have built their infrastructure using these principles, handling millions of concurrent connections with minimal hardware.",
        snippet: "Practical applications and case studies",
        retrieved_at: DateTime.utc_now()
      }
    }

    key = cond do
      String.contains?(query, "overview") or String.contains?(query, "introduction") -> "overview"
      String.contains?(query, "concepts") or String.contains?(query, "fundamentals") -> "concepts"
      String.contains?(query, "applications") or String.contains?(query, "examples") -> "applications"
      true -> "overview"
    end

    Map.get(docs, key)
  end

  def claims_for(%SourceDoc{url: url, content: content}) do
    sentences = String.split(content, ". ") |> Enum.take(3)

    sentences
    |> Enum.with_index()
    |> Enum.map(fn {sentence, idx} ->
      %Claim{
        text: String.trim(sentence) <> ".",
        quote: sentence,
        url: url,
        confidence: 0.85 + idx * 0.05,
        tags: extract_tags(sentence)
      }
    end)
  end

  def outline_for(topic, claims) do
    all_tags = claims |> Enum.flat_map(& &1.tags) |> Enum.uniq()

    sections = [
      %OutlineSection{
        id: "intro",
        title: "Introduction to #{topic}",
        intent: "Provide overview and context",
        required_tags: Enum.take(all_tags, 2)
      },
      %OutlineSection{
        id: "concepts",
        title: "Core Concepts",
        intent: "Explain fundamental principles",
        required_tags: Enum.slice(all_tags, 1..3)
      },
      %OutlineSection{
        id: "applications",
        title: "Real-World Applications",
        intent: "Show practical usage",
        required_tags: Enum.drop(all_tags, 2) |> Enum.take(2)
      }
    ]

    %Outline{topic: topic, sections: sections}
  end

  def draft_for(%OutlineSection{} = section, claims) do
    relevant = Enum.filter(claims, fn c ->
      Enum.any?(section.required_tags, &(&1 in c.tags))
    end)

    body = relevant
    |> Enum.map(fn c -> "#{c.text} [Source: #{c.url}]" end)
    |> Enum.join("\n\n")

    %SectionDraft{
      section_id: section.id,
      title: section.title,
      markdown: "## #{section.title}\n\n#{body}",
      citations: Enum.map(relevant, & &1.url) |> Enum.uniq(),
      used_claim_hashes: Enum.map(relevant, &:erlang.phash2(&1))
    }
  end

  def assemble_article(drafts, _sources, _claims) do
    sorted = Enum.sort_by(drafts, & &1.section_id)

    markdown = sorted
    |> Enum.map(& &1.markdown)
    |> Enum.join("\n\n---\n\n")

    all_citations = sorted |> Enum.flat_map(& &1.citations) |> Enum.uniq()

    %Article{
      markdown: "# Research Article\n\n#{markdown}\n\n## References\n\n#{Enum.map_join(all_citations, "\n", &"- #{&1}")}",
      quality_score: 0.82,
      citations: all_citations,
      sections: Enum.map(sorted, & &1.section_id)
    }
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp titleize(text) do
    text
    |> String.split(~r/[\s_-]+/)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp extract_tags(text) do
    keywords = ["scalable", "fault-tolerant", "processes", "message passing",
                "immutability", "pattern matching", "recursion", "actor model",
                "web servers", "real-time", "distributed", "concurrent"]

    downcased = String.downcase(text)
    Enum.filter(keywords, &String.contains?(downcased, &1))
  end
end
