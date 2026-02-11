# Structured LLM Branching Demo
#
# Demonstrates dynamic workflow branching driven by structured LLM
# structured object response:
#
#   Phase 1: RouteQuestion (returns question/route/detail_level/confidence/reasoning)
#   Phase 2:
#     - :direct   -> DirectAnswer
#     - :analysis -> AnalysisPlan -> AnalysisAnswer
#     - :safe     -> SafeResponse
#
# Run with: cd projects/jido_runic && mix run lib/examples/branching_demo.exs

env_file = Path.expand("../../.env", __DIR__)

if File.regular?(env_file) do
  Dotenv.load!(env_file)
end

alias Jido.Runic.Examples.Branching.LLMBranchingOrchestrator

question =
  System.get_env(
    "BRANCHING_QUESTION",
    "What is a practical migration strategy from a Rails monolith to services?"
  )

Process.flag(:trap_exit, true)

IO.puts("\n#{String.duplicate("=", 70)}")
IO.puts("  Structured LLM Branching Demo")
IO.puts("#{String.duplicate("=", 70)}")
IO.puts("\nQuestion: #{question}")
IO.puts("")

{:ok, jido_pid} = Jido.start_link(name: BranchingDemo.Jido)
Process.unlink(jido_pid)

result = LLMBranchingOrchestrator.run(question, jido: BranchingDemo.Jido, timeout: 120_000)

IO.puts("\n#{String.duplicate("-", 70)}")
IO.puts("  RESULTS")
IO.puts("#{String.duplicate("-", 70)}")
IO.puts("\nStatus:         #{inspect(result.status)}")
IO.puts("Selected branch: #{inspect(result.selected_branch)}")

if is_map(result.decision) do
  decision = result.decision
  IO.puts("Route:          #{inspect(decision.route)}")
  IO.puts("Detail level:   #{inspect(decision.detail_level)}")
  IO.puts("Confidence:     #{:erlang.float_to_binary(decision.confidence, decimals: 2)}")
  IO.puts("Reasoning:      #{decision.reasoning}")
end

case LLMBranchingOrchestrator.branch_output(result) do
  %{branch_result: text} ->
    IO.puts("\nBranch output:\n#{text}")

  _ ->
    IO.puts("\nNo branch output produced.")
end

IO.puts("")
Jido.stop(BranchingDemo.Jido)
