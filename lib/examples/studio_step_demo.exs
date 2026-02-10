# AI Research Studio — Step-Mode Demo
#
# Demonstrates step-wise execution of the same 5-node LLM pipeline,
# pausing between each node to show the annotated workflow graph,
# step history, and data flowing through the pipeline.
#
# Pipeline: PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble
#
# Run with: cd projects/jido_runic && mix run lib/examples/studio_step_demo.exs

env_file = Path.expand("../../.env", __DIR__)

if File.regular?(env_file) do
  Dotenv.load!(env_file)
end

alias Jido.Runic.Examples.Studio.OrchestratorAgent
alias Jido.Runic.Introspection

topic = System.get_env("STUDIO_TOPIC", "Elixir Concurrency")

IO.puts("\n#{String.duplicate("=", 70)}")
IO.puts("  AI Research Studio — Step-Mode Execution")
IO.puts("#{String.duplicate("=", 70)}")
IO.puts("\nTopic: #{topic}")
IO.puts("Pipeline: PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble\n")

{:ok, _} = Jido.start_link(name: StudioStepDemo.Jido)

# Show the workflow graph before execution
workflow = OrchestratorAgent.build_workflow()
node_map = Introspection.node_map(workflow)

IO.puts("Workflow Nodes:")

Enum.each(node_map, fn {name, info} ->
  IO.puts("  #{name} (#{info.type}) → #{inspect(info.action_mod)}")
end)

IO.puts("")

# on_step callback prints step details as they complete
on_step = fn step_info ->
  IO.puts("\n#{String.duplicate("-", 70)}")
  IO.puts("STEP #{step_info.step_index}")
  IO.puts("#{String.duplicate("-", 70)}")
  IO.puts("  Dispatched: #{inspect(step_info.nodes_dispatched)}")
  IO.puts("  Status:     #{step_info.status}")

  Enum.each(step_info.completed_entries, fn entry ->
    IO.puts("\n  Node: #{entry.node} (#{entry.action})")
    IO.puts("  Result: #{entry.status}")

    if entry.output do
      keys = Map.keys(entry.output)
      IO.puts("  Output keys: #{inspect(keys)}")

      preview =
        entry.output
        |> inspect(pretty: true, limit: 5, printable_limit: 200)
        |> String.split("\n")
        |> Enum.map(&("    " <> &1))
        |> Enum.join("\n")

      IO.puts("  Output:\n#{preview}")
    end

    if entry.error do
      IO.puts("  Error: #{inspect(entry.error)}")
    end
  end)

  IO.puts("\n  Graph:")

  Enum.each(step_info.graph_after.nodes, fn node ->
    icon =
      case node.status do
        :completed -> "[done]"
        :pending -> "[....]"
        :idle -> "[    ]"
        :failed -> "[FAIL]"
        other -> "[#{other}]"
      end

    IO.puts("    #{icon} #{node.name}")
  end)

  IO.puts("  Summary: #{inspect(step_info.summary)}")
end

result =
  OrchestratorAgent.run_step(topic,
    jido: StudioStepDemo.Jido,
    timeout: 120_000,
    on_step: on_step
  )

IO.puts("\n#{String.duplicate("=", 70)}")
IO.puts("  FINAL RESULT")
IO.puts("#{String.duplicate("=", 70)}")
IO.puts("\nStatus: #{result.status}")
IO.puts("Steps completed: #{length(result.steps)}")
IO.puts("Productions: #{length(result.productions)}")
IO.puts("Summary: #{inspect(result.summary)}")

case OrchestratorAgent.article(result) do
  %{markdown: markdown} when is_binary(markdown) ->
    slug = topic |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    filename = "studio_step_output_#{slug}.md"
    File.write!(filename, markdown)
    IO.puts("\nArticle written to: #{filename}")

  _ ->
    IO.puts("\nNo article markdown produced.")
end

IO.puts("")
Jido.stop(StudioStepDemo.Jido)
