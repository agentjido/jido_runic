# Run with: cd projects/jido_runic && mix run lib/examples/studio_demo.exs

alias JidoRunic.Examples.Studio.OrchestratorAgent

topic = System.get_env("STUDIO_TOPIC", "Elixir Concurrency")

IO.puts("Starting AI Research Studio...")
IO.puts("Topic: #{topic}")
IO.puts("")

result = OrchestratorAgent.run(topic, timeout: 60_000)

IO.puts("Status: #{result.status}")
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
