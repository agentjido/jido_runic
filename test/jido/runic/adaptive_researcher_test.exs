defmodule Jido.RunicTest.AdaptiveResearcherTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.Examples.Adaptive.AdaptiveResearcher
  alias Jido.Runic.Strategy
  alias Jido.Runic.Directive.ExecuteRunnable
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable}

  # -- Helpers -----------------------------------------------------------------

  defp make_agent(workflow, opts \\ []) do
    strategy_opts = [workflow: workflow] ++ opts
    ctx = %{strategy_opts: strategy_opts}

    agent = %Jido.Agent{
      id: "adaptive-#{System.unique_integer([:positive])}",
      name: "adaptive_test",
      description: "test",
      schema: [],
      state: %{}
    }

    {agent, _directives} = Strategy.init(agent, ctx)
    agent
  end

  defp get_strat(agent), do: StratState.get(agent)

  defp feed(agent, data) do
    instruction = %Jido.Instruction{action: :runic_feed_signal, params: %{data: data}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp apply_result(agent, runnable) do
    instruction = %Jido.Instruction{action: :runic_apply_result, params: %{runnable: runnable}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp set_workflow(agent, workflow) do
    instruction = %Jido.Instruction{action: :runic_set_workflow, params: %{workflow: workflow}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp extract_execute_runnables(directives) do
    Enum.filter(directives, &match?(%ExecuteRunnable{}, &1))
  end

  defp simulate_completion(%ExecuteRunnable{runnable: runnable}, result_value) do
    node = runnable.node
    fact = runnable.input_fact
    result_fact = Fact.new(value: result_value, ancestry: {node.hash, fact.hash})

    apply_fn = fn workflow ->
      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(node, result_fact, :produced)
      |> Workflow.prepare_next_runnables(node, result_fact)
      |> Workflow.mark_runnable_as_ran(node, fact)
    end

    Runnable.complete(runnable, result_fact, apply_fn)
  end

  defp rich_summary, do: String.duplicate("Research findings about Elixir. ", 20)
  defp thin_summary, do: "Brief results."

  # -- Phase 1 Workflow Tests --------------------------------------------------

  describe "build_phase_1/0" do
    test "creates a 2-node workflow" do
      workflow = AdaptiveResearcher.build_phase_1()

      assert %Workflow{} = workflow
      assert workflow.name == :phase_1_research
    end

    test "phase 1 workflow accepts topic input and produces directives" do
      workflow = AdaptiveResearcher.build_phase_1()
      agent = make_agent(workflow)

      {agent, directives} = feed(agent, %{topic: "Elixir OTP"})

      runnables = extract_execute_runnables(directives)
      assert length(runnables) == 1
      assert get_strat(agent).status == :running
    end
  end

  # -- Phase 2 Workflow Tests --------------------------------------------------

  describe "build_phase_2/1" do
    test "rich results produce a 3-node full pipeline" do
      productions = [%{topic: "Elixir", research_summary: rich_summary()}]

      workflow = AdaptiveResearcher.build_phase_2(productions)

      assert workflow.name == :phase_2_full
    end

    test "thin results produce a 2-node slim pipeline" do
      productions = [%{topic: "Elixir", research_summary: thin_summary()}]

      workflow = AdaptiveResearcher.build_phase_2(productions)

      assert workflow.name == :phase_2_slim
    end

    test "empty productions default to slim pipeline" do
      workflow = AdaptiveResearcher.build_phase_2([])

      assert workflow.name == :phase_2_slim
    end
  end

  # -- Hot-Swap Workflow Tests -------------------------------------------------

  describe "workflow hot-swap via set_workflow" do
    test "set_workflow resets strategy state to idle" do
      phase_1 = AdaptiveResearcher.build_phase_1()
      agent = make_agent(phase_1)

      {agent, _directives} = feed(agent, %{topic: "Elixir"})
      assert get_strat(agent).status == :running

      phase_2 = AdaptiveResearcher.build_phase_2([%{topic: "Elixir", research_summary: rich_summary()}])
      {agent, []} = set_workflow(agent, phase_2)

      strat = get_strat(agent)
      assert strat.status == :idle
      assert strat.pending == %{}
      assert strat.ran_nodes == MapSet.new()
      assert strat.step_history == []
      assert strat.held_runnables == []
    end

    test "can feed data into the new workflow after hot-swap" do
      phase_1 = AdaptiveResearcher.build_phase_1()
      agent = make_agent(phase_1)

      phase_2 = AdaptiveResearcher.build_phase_2([%{topic: "Elixir", research_summary: rich_summary()}])
      {agent, []} = set_workflow(agent, phase_2)

      {agent, directives} = feed(agent, %{topic: "Elixir", research_summary: rich_summary()})
      runnables = extract_execute_runnables(directives)

      assert length(runnables) == 1
      assert get_strat(agent).status == :running
    end

    test "full pipeline swap — slim phase 2 accepts outline input" do
      phase_1 = AdaptiveResearcher.build_phase_1()
      agent = make_agent(phase_1)

      phase_2 = AdaptiveResearcher.build_phase_2([%{topic: "Elixir", research_summary: thin_summary()}])
      {agent, []} = set_workflow(agent, phase_2)

      {agent, directives} = feed(agent, %{topic: "Elixir", outline: ["Section 1"]})
      runnables = extract_execute_runnables(directives)

      assert length(runnables) == 1
      assert get_strat(agent).status == :running
    end
  end

  # -- Article Extraction Tests ------------------------------------------------

  describe "article/1" do
    test "extracts markdown from productions" do
      result = %{productions: [%{markdown: "# Hello", quality_score: 0.85}]}

      assert %{markdown: "# Hello"} = AdaptiveResearcher.article(result)
    end

    test "returns nil when no markdown production exists" do
      result = %{productions: [%{topic: "Elixir"}]}

      assert AdaptiveResearcher.article(result) == nil
    end
  end

  # -- End-to-End Strategy-Level Test ------------------------------------------

  describe "end-to-end strategy-level orchestration" do
    test "simulates full phase 1 → hot-swap → phase 2 (rich) cycle" do
      phase_1 = AdaptiveResearcher.build_phase_1()
      agent = make_agent(phase_1)

      # Phase 1: Feed topic — dispatches PlanQueries
      {agent, [d1]} = feed(agent, %{topic: "Testing"})
      assert %ExecuteRunnable{} = d1

      # Simulate PlanQueries completing with synthetic output
      completed_1 =
        simulate_completion(d1, %{
          topic: "Testing",
          queries: ["query 1", "query 2", "query 3"],
          outline_seed: ["Intro", "Body", "Conclusion"]
        })

      {agent, directives_2} = apply_result(agent, completed_1)
      runnables_2 = extract_execute_runnables(directives_2)
      assert length(runnables_2) == 1

      # Simulate SimulateSearch completing with rich research summary
      completed_2 =
        simulate_completion(hd(runnables_2), %{
          topic: "Testing",
          research_summary: rich_summary()
        })

      {agent, _directives_3} = apply_result(agent, completed_2)

      strat = get_strat(agent)
      assert strat.status == :success

      productions = Workflow.raw_productions(strat.workflow)
      assert length(productions) >= 1

      # Hot-swap to Phase 2 (rich → full pipeline)
      phase_2 = AdaptiveResearcher.build_phase_2(productions)
      assert phase_2.name == :phase_2_full

      {agent, []} = set_workflow(agent, phase_2)
      assert get_strat(agent).status == :idle

      # Feed Phase 1 data into Phase 2
      {agent, phase_2_directives} =
        feed(agent, %{topic: "Testing", research_summary: rich_summary()})

      phase_2_runnables = extract_execute_runnables(phase_2_directives)
      assert length(phase_2_runnables) == 1
      assert get_strat(agent).status == :running
    end

    test "simulates full phase 1 → hot-swap → phase 2 (thin) cycle" do
      phase_1 = AdaptiveResearcher.build_phase_1()
      agent = make_agent(phase_1)

      {agent, [d1]} = feed(agent, %{topic: "Testing"})

      completed_1 =
        simulate_completion(d1, %{
          topic: "Testing",
          queries: ["query 1"],
          outline_seed: ["Intro"]
        })

      {agent, directives_2} = apply_result(agent, completed_1)
      [d2] = extract_execute_runnables(directives_2)

      completed_2 =
        simulate_completion(d2, %{
          topic: "Testing",
          research_summary: thin_summary()
        })

      {agent, _} = apply_result(agent, completed_2)
      assert get_strat(agent).status == :success

      productions = Workflow.raw_productions(get_strat(agent).workflow)

      phase_2 = AdaptiveResearcher.build_phase_2(productions)
      assert phase_2.name == :phase_2_slim

      {agent, []} = set_workflow(agent, phase_2)

      {agent, phase_2_directives} =
        feed(agent, %{topic: "Testing", outline: [thin_summary()]})

      phase_2_runnables = extract_execute_runnables(phase_2_directives)
      assert length(phase_2_runnables) == 1
      assert get_strat(agent).status == :running
    end
  end
end
