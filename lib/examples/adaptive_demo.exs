# Adaptive Researcher Demo
#
# Demonstrates dynamic workflow construction and hot-swapping.
# Phase 1: PlanQueries → SimulateSearch
# Phase 2: Dynamically chosen based on Phase 1 results
#   Rich → BuildOutline → DraftArticle → EditAndAssemble
#   Thin → DraftArticle → EditAndAssemble
#
# Run with: cd projects/jido_runic && mix run lib/examples/adaptive_demo.exs

alias Jido.Runic.Examples.Adaptive.AdaptiveResearcher

topic = System.get_env("ADAPTIVE_TOPIC", "Elixir GenServer Patterns")

IO.puts("\n#{String.duplicate("=", 70)}")
IO.puts("  Adaptive Researcher — Dynamic Workflow Demo")
IO.puts("#{String.duplicate("=", 70)}")
IO.puts("\nTopic: #{topic}")
IO.puts("")

{:ok, _} = Jido.start_link(name: AdaptiveDemo.Jido)

result = AdaptiveResearcher.run(topic, jido: AdaptiveDemo.Jido, timeout: 120_000)

IO.puts("\n#{String.duplicate("-", 70)}")
IO.puts("  RESULTS")
IO.puts("#{String.duplicate("-", 70)}")
IO.puts("\nStatus:     #{inspect(result.status)}")
IO.puts("Phase 2:    #{result.phase_2_type}")
IO.puts("Productions: #{length(result.productions)}")

case AdaptiveResearcher.article(result) do
  %{markdown: markdown} when is_binary(markdown) ->
    slug = topic |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    filename = "adaptive_output_#{slug}.md"
    File.write!(filename, markdown)
    IO.puts("Article written to: #{filename}")

  _ ->
    IO.puts("No article markdown produced.")
end

IO.puts("")
Jido.stop(AdaptiveDemo.Jido)
