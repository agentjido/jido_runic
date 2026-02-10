# AI Research Studio Demo
#
# Demonstrates a Runic workflow-powered research pipeline using
# Jido.Runic.Strategy as the agent strategy.
#
# Pipeline: PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble
#
# Run with: cd projects/jido_runic && mix run lib/examples/studio_demo.exs

env_file = Path.expand("../../.env", __DIR__)

if File.regular?(env_file) do
  Dotenv.load!(env_file)
end

alias Jido.Runic.Examples.Studio.OrchestratorAgent

topic = System.get_env("STUDIO_TOPIC", "Elixir Concurrency")

IO.puts("\nStarting AI Research Studio...")
IO.puts("Topic: #{topic}")
IO.puts("")

{:ok, _} = Jido.start_link(name: StudioDemo.Jido)

result = OrchestratorAgent.run(topic, jido: StudioDemo.Jido, timeout: 120_000)

IO.puts("\nStatus: #{result.status}")
IO.puts("Productions: #{length(result.productions)}")
IO.puts("Facts: #{length(result.facts)}")
IO.puts("Events: #{length(result.events)}")

case OrchestratorAgent.article(result) do
  %{markdown: markdown} when is_binary(markdown) ->
    slug = topic |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    filename = "studio_output_#{slug}.md"
    File.write!(filename, markdown)
    IO.puts("Article written to: #{filename}")

  _ ->
    IO.puts("No article markdown produced.")
end

Jido.stop(StudioDemo.Jido)
