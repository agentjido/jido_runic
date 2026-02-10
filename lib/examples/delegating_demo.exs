# Delegating Orchestrator — Multi-Agent Demo
#
# Demonstrates multi-agent workflow orchestration where an orchestrator
# agent runs a Runic workflow DAG but delegates specific nodes to child
# agents rather than executing them locally.
#
# Pipeline:
#   PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble
#   [  local  ]   [   local    ]   [  local   ]   [ child:    ]   [ child:     ]
#                                                  [ drafter  ]   [ editor     ]
#
# Flow:
#   1. Orchestrator runs PlanQueries, SimulateSearch, BuildOutline locally
#   2. DraftArticle is delegated — spawns DrafterAgent child, sends work, receives result
#   3. EditAndAssemble is delegated — spawns EditorAgent child, sends work, receives result
#   4. Workflow completes with final article
#
# Run with: cd projects/jido_runic && mix run lib/examples/delegating_demo.exs

env_file = Path.expand("../../.env", __DIR__)

if File.regular?(env_file) do
  Dotenv.load!(env_file)
end

alias Jido.Runic.Examples.Delegating.DelegatingOrchestrator
alias Jido.Runic.Introspection

topic = System.get_env("DELEGATING_TOPIC", "Multi-Agent Systems in Elixir")

IO.puts("\n#{String.duplicate("=", 70)}")
IO.puts("  Delegating Orchestrator — Multi-Agent Demo")
IO.puts("#{String.duplicate("=", 70)}")
IO.puts("\nTopic: #{topic}")

# Show the workflow graph with executor annotations
workflow = DelegatingOrchestrator.build_workflow()
node_map = Introspection.node_map(workflow)
components = Runic.Workflow.components(workflow)

IO.puts("\nWorkflow Nodes:")

Enum.each(node_map, fn {name, info} ->
  node = Map.get(components, name)

  executor_label =
    case node do
      %Jido.Runic.ActionNode{executor: {:child, tag}} -> " → child:#{tag}"
      _ -> " → local"
    end

  IO.puts("  #{name} (#{info.type})#{executor_label} — #{inspect(info.action_mod)}")
end)

IO.puts("\nPipeline: PlanQueries → SimulateSearch → BuildOutline → DraftArticle → EditAndAssemble")
IO.puts("                                                        [drafter]       [editor]")
IO.puts("")

{:ok, _} = Jido.start_link(name: DelegatingDemo.Jido)

result = DelegatingOrchestrator.run(topic, jido: DelegatingDemo.Jido, timeout: 120_000)

IO.puts("\n#{String.duplicate("-", 70)}")
IO.puts("  RESULTS")
IO.puts("#{String.duplicate("-", 70)}")
IO.puts("\nStatus:      #{inspect(result.status)}")
IO.puts("Productions: #{length(result.productions)}")

case DelegatingOrchestrator.article(result) do
  %{markdown: markdown} when is_binary(markdown) ->
    slug = topic |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    filename = "delegating_output_#{slug}.md"
    File.write!(filename, markdown)
    IO.puts("Article written to: #{filename}")

  _ ->
    IO.puts("No article markdown produced.")
end

IO.puts("")
Jido.stop(DelegatingDemo.Jido)
