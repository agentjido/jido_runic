# Run with: cd projects/jido_runic && mix run lib/examples/studio_demo.exs
#
# For live LLM mode (requires ANTHROPIC_API_KEY in .env):
#   STUDIO_LIVE=1 mix run lib/examples/studio_demo.exs

alias JidoRunic.Examples.Studio.Pipeline

topic = System.get_env("STUDIO_TOPIC", "Elixir Concurrency")
live_mode = System.get_env("STUDIO_LIVE") == "1"

IO.puts("Starting AI Research Studio...")
IO.puts("Topic: #{topic}")
IO.puts("Mode: #{if live_mode, do: "LIVE (LLM)", else: "MOCK (fixtures)"}")
IO.puts("")

result = Pipeline.run(topic, mock: !live_mode)
Pipeline.print_summary(result)

case Pipeline.article(result) do
  %{markdown: markdown} when is_binary(markdown) ->
    slug = topic |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    filename = "studio_output_#{slug}.md"
    File.write!(filename, markdown)
    IO.puts("Article written to: #{filename}")

  _ ->
    IO.puts("No article markdown produced.")
end
