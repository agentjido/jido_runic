defmodule JidoRunic.Examples.Studio.Pipeline do
  @moduledoc """
  AI Research Studio pipeline using Runic workflows with Jido Actions.

  Demonstrates:
  - ActionNodes wrapping Jido Actions in a Runic DAG
  - Sequential pipeline: plan → search → extract → outline → draft → edit
  - Full provenance tracking via Runic Fact ancestry
  - Mock mode (deterministic fixtures) and live mode (real LLM calls)

  Because the pipeline actions have different input/output schemas that don't
  directly chain (e.g., PlanQueries outputs `queries` but WebSearch expects
  a single `query`), we drive each stage as its own mini-workflow and thread
  provenance facts manually. This still demonstrates the DAG, ActionNode
  execution, and full provenance chains.
  """

  alias JidoRunic.ActionNode
  alias Runic.Workflow
  alias JidoRunic.Examples.Studio.Actions
  alias JidoRunic.Examples.Studio.BatchActions
  alias JidoRunic.Strategy
  alias JidoRunic.Directive.ExecuteRunnable
  alias Jido.Agent.Strategy.State, as: StratState

  @doc """
  Build individual ActionNode stages for introspection.
  Returns a map of stage name to ActionNode.
  """
  def build_stages do
    %{
      plan_queries: ActionNode.new(Actions.PlanQueries, %{}, name: :plan_queries),
      web_search: ActionNode.new(Actions.WebSearch, %{}, name: :web_search),
      extract_claims: ActionNode.new(Actions.ExtractClaims, %{}, name: :extract_claims),
      build_outline: ActionNode.new(Actions.BuildOutline, %{}, name: :build_outline),
      draft_section: ActionNode.new(Actions.DraftSection, %{}, name: :draft_section),
      edit_and_assemble: ActionNode.new(Actions.EditAndAssemble, %{}, name: :edit_and_assemble)
    }
  end

  @doc """
  Build a two-step workflow demonstrating DAG chaining.
  This chains plan_queries → web_search via a single `react_until_satisfied`.
  (Used for the workflow integration test.)
  """
  def build_workflow do
    plan = ActionNode.new(Actions.PlanQueries, %{}, name: :plan_queries)

    Workflow.new(:research_studio)
    |> Workflow.add(plan)
  end

  @doc """
  Run the full research pipeline for a given topic.

  Executes each stage as a Runic workflow step, threading facts between them
  to maintain provenance. Returns the collected facts and final productions.
  """
  def run(topic, opts \\ []) do
    mock_mode = Keyword.get(opts, :mock, true)
    Application.put_env(:jido_runic, :studio_mock_mode, mock_mode)

    stages = build_stages()

    # Stage 1: Plan Queries
    plan_input = %{topic: topic, audience: "general", num_queries: 3}
    {plan_result, plan_facts} = run_stage(stages.plan_queries, plan_input)

    # Stage 2: Web Search (fan-out over queries)
    queries = Map.get(plan_result, :queries, [])
    {search_results, search_facts} =
      queries
      |> Enum.map(fn query ->
        run_stage(stages.web_search, %{query: query}, List.last(plan_facts))
      end)
      |> Enum.unzip()
      |> then(fn {results, fact_lists} -> {results, List.flatten(fact_lists)} end)

    # Stage 3: Extract Claims (fan-out over search results)
    {claim_results, claim_facts} =
      search_results
      |> Enum.map(fn source ->
        input = %{
          content: Map.get(source, :content, ""),
          url: Map.get(source, :url, "")
        }
        parent = List.last(search_facts)
        run_stage(stages.extract_claims, input, parent)
      end)
      |> Enum.unzip()
      |> then(fn {results, fact_lists} -> {results, List.flatten(fact_lists)} end)

    # Stage 4: Build Outline
    all_claims = Enum.flat_map(claim_results, fn r -> Map.get(r, :claims, []) end)
    claims_summary = all_claims |> Enum.map(& &1["text"] || Map.get(&1, :text, "")) |> Enum.join("; ")
    outline_input = %{topic: topic, claims_summary: claims_summary}
    {outline_result, outline_facts} = run_stage(stages.build_outline, outline_input, List.last(claim_facts))

    # Stage 5: Draft Sections
    sections = Map.get(outline_result, :sections, [])
    {draft_results, draft_facts} =
      sections
      |> Enum.map(fn section ->
        input = %{
          section_id: section["id"] || Map.get(section, :id, "section"),
          title: section["title"] || Map.get(section, :title, "Section"),
          intent: section["intent"] || Map.get(section, :intent, ""),
          claims_text: claims_summary
        }
        parent = List.last(outline_facts)
        run_stage(stages.draft_section, input, parent)
      end)
      |> Enum.unzip()
      |> then(fn {results, fact_lists} -> {results, List.flatten(fact_lists)} end)

    # Stage 6: Edit and Assemble
    drafts_text =
      draft_results
      |> Enum.map(fn d -> Map.get(d, :markdown, "") end)
      |> Enum.join("\n\n---\n\n")

    edit_input = %{drafts_text: drafts_text, topic: topic}
    {_edit_result, edit_facts} = run_stage(stages.edit_and_assemble, edit_input, List.last(draft_facts))

    all_facts = plan_facts ++ search_facts ++ claim_facts ++ outline_facts ++ draft_facts ++ edit_facts

    productions =
      edit_facts
      |> Enum.map(fn f -> f.value end)

    %{
      workflow: nil,
      productions: productions,
      facts: all_facts,
      topic: topic,
      mock_mode: mock_mode
    }
  end

  defp run_stage(action_node, input, parent_fact \\ nil) do
    workflow = Workflow.new(:stage) |> Workflow.add(action_node)

    completed = Workflow.react_until_satisfied(workflow, input)
    productions = Workflow.raw_productions(completed)
    facts = Workflow.facts(completed)

    result_facts =
      facts
      |> Enum.map(fn fact ->
        if parent_fact && fact.ancestry != nil do
          %{fact | ancestry: {action_node.hash, parent_fact.hash}}
        else
          fact
        end
      end)

    result = List.last(productions) || input
    {result, result_facts}
  end

  @doc """
  Build a linear Runic DAG using batch adapter actions for Strategy-driven execution.

  Pipeline: PlanQueries → WebSearchBatch → ExtractClaimsBatch → BuildOutline → DraftSectionsBatch → EditAndAssemble
  """
  def build_strategy_workflow do
    plan = ActionNode.new(Actions.PlanQueries, %{}, name: :plan_queries)
    search = ActionNode.new(BatchActions.WebSearchBatch, %{}, name: :web_search_batch)
    extract = ActionNode.new(BatchActions.ExtractClaimsBatch, %{}, name: :extract_claims_batch)
    outline = ActionNode.new(Actions.BuildOutline, %{}, name: :build_outline)
    draft = ActionNode.new(BatchActions.DraftSectionsBatch, %{}, name: :draft_sections_batch)
    edit = ActionNode.new(Actions.EditAndAssemble, %{}, name: :edit_and_assemble)

    Workflow.new(:research_studio_strategy)
    |> Workflow.add(plan)
    |> Workflow.add(search, to: :plan_queries)
    |> Workflow.add(extract, to: :web_search_batch)
    |> Workflow.add(outline, to: :extract_claims_batch)
    |> Workflow.add(draft, to: :build_outline)
    |> Workflow.add(edit, to: :draft_sections_batch)
  end

  @doc """
  Run the full pipeline through the JidoRunic.Strategy loop.

  Uses the OrchestratorAgent to drive the workflow via Strategy commands,
  executing runnables and applying results until the workflow is satisfied.
  """
  def run_strategy(topic, opts \\ []) do
    mock_mode = Keyword.get(opts, :mock, true)
    Application.put_env(:jido_runic, :studio_mock_mode, mock_mode)

    workflow = build_strategy_workflow()
    agent = JidoRunic.Examples.Studio.OrchestratorAgent.new()
    ctx = %{agent_module: JidoRunic.Examples.Studio.OrchestratorAgent, strategy_opts: []}

    set_instr = %Jido.Instruction{action: :runic_set_workflow, params: %{workflow: workflow}}
    {agent, []} = Strategy.cmd(agent, [set_instr], ctx)

    input = %{topic: topic, audience: "general", num_queries: 3}
    feed_instr = %Jido.Instruction{action: :runic_feed_signal, params: %{data: input}}
    {agent, directives} = Strategy.cmd(agent, [feed_instr], ctx)

    {agent, final_directives} = execute_loop(agent, directives, ctx)

    strat = StratState.get(agent)
    facts = Workflow.facts(strat.workflow)

    productions =
      final_directives
      |> Enum.filter(&match?(%Jido.Agent.Directive.Emit{}, &1))
      |> Enum.map(& &1.signal.data)

    %{
      workflow: strat.workflow,
      productions: productions,
      facts: facts,
      topic: topic,
      mock_mode: mock_mode,
      status: strat.status
    }
  end

  defp execute_loop(agent, directives, ctx) do
    exec_directives = Enum.filter(directives, &match?(%ExecuteRunnable{}, &1))
    emit_directives = Enum.reject(directives, &match?(%ExecuteRunnable{}, &1))

    if exec_directives == [] do
      {agent, emit_directives}
    else
      {agent, new_directives} =
        Enum.reduce(exec_directives, {agent, []}, fn exec_dir, {agent_acc, dirs_acc} ->
          executed = Strategy.execute_runnable(exec_dir)
          apply_instr = %Jido.Instruction{action: :runic_apply_result, params: %{runnable: executed}}
          {updated_agent, result_dirs} = Strategy.cmd(agent_acc, [apply_instr], ctx)
          {updated_agent, dirs_acc ++ result_dirs}
        end)

      {agent, more_emits} = execute_loop(agent, new_directives, ctx)
      {agent, emit_directives ++ more_emits}
    end
  end

  @doc """
  Extract the final article from pipeline results.
  """
  def article(%{productions: productions}) do
    productions
    |> Enum.filter(fn
      %{markdown: _} -> true
      _ -> false
    end)
    |> List.last()
  end

  @doc """
  Trace provenance for a given fact through the workflow.
  Returns the chain of facts from root to leaf.
  """
  def trace_provenance(%{facts: facts}, target_hash) do
    facts_by_hash = Map.new(facts, fn f -> {f.hash, f} end)

    do_trace(facts_by_hash, target_hash, [])
  end

  defp do_trace(_facts_map, nil, acc), do: Enum.reverse(acc)

  defp do_trace(facts_map, hash, acc) do
    case Map.get(facts_map, hash) do
      nil ->
        Enum.reverse(acc)

      fact ->
        parent_hash =
          case fact.ancestry do
            {_producer, parent} -> parent
            _ -> nil
          end

        do_trace(facts_map, parent_hash, [fact | acc])
    end
  end

  @doc """
  Print a summary of the pipeline run.
  """
  def print_summary(result) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("AI RESEARCH STUDIO — Pipeline Results")
    IO.puts(String.duplicate("=", 60))
    IO.puts("Topic: #{result.topic}")
    IO.puts("Mode: #{if result.mock_mode, do: "MOCK (fixtures)", else: "LIVE (LLM)"}")
    IO.puts("Total facts produced: #{length(result.facts)}")
    IO.puts("Final productions: #{length(result.productions)}")
    IO.puts(String.duplicate("-", 60))

    case article(result) do
      nil ->
        IO.puts("\nNo article produced. Productions:")

        Enum.each(result.productions, fn p ->
          IO.puts("  - #{inspect(p, limit: 100)}")
        end)

      art ->
        IO.puts("\nArticle Preview (first 500 chars):")
        IO.puts(String.slice(art.markdown || inspect(art), 0, 500))
        IO.puts("...")
    end

    IO.puts("\nProvenance Chain (last production -> root):")

    case List.last(result.facts) do
      nil ->
        IO.puts("  No facts to trace")

      fact ->
        chain = trace_provenance(result, fact.hash)

        Enum.each(chain, fn f ->
          label =
            case f.value do
              %{topic: t} -> "Topic: #{t}"
              %{markdown: _} -> "Article/Draft"
              %{claims: _} -> "Claims"
              %{sections: _} -> "Outline"
              %{url: u} -> "Source: #{u}"
              %{queries: _} -> "Query Plan"
              other -> inspect(other, limit: 50)
            end

          IO.puts("  -> #{label} [hash: #{f.hash}]")
        end)
    end

    IO.puts(String.duplicate("=", 60) <> "\n")
    result
  end
end
