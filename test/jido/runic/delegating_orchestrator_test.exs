defmodule Jido.RunicTest.DelegatingOrchestratorTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.Examples.Delegating.{
    DelegatingOrchestrator,
    DrafterAgent,
    EditorAgent
  }

  alias Jido.Runic.Strategy
  alias Jido.Runic.ActionNode
  alias Jido.Runic.Directive.ExecuteRunnable
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable}

  # -- Helpers -----------------------------------------------------------------

  defp make_agent(workflow, opts \\ []) do
    strategy_opts = [workflow: workflow] ++ opts
    ctx = %{strategy_opts: strategy_opts}

    agent = %Jido.Agent{
      id: "delegating-#{System.unique_integer([:positive])}",
      name: "delegating_test",
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

  defp child_dispatch(agent, params) do
    instruction = %Jido.Instruction{action: :runic_child_dispatch, params: params}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp child_started(agent, params) do
    instruction = %Jido.Instruction{action: :runic_child_started, params: params}
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

  defp simulate_runnable_completion(runnable, result_value) do
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

  # -- Workflow Construction Tests ---------------------------------------------

  describe "build_workflow/0" do
    test "creates a 5-node workflow with delegated nodes" do
      workflow = DelegatingOrchestrator.build_workflow()

      assert %Workflow{} = workflow
      assert workflow.name == :delegating_pipeline
    end

    test "draft_article node has {:child, :drafter} executor" do
      workflow = DelegatingOrchestrator.build_workflow()
      agent = make_agent(workflow)

      {agent, [d1]} = feed(agent, %{topic: "Test"})

      completed_1 =
        simulate_completion(d1, %{
          topic: "Test",
          queries: ["q1"],
          outline_seed: ["Intro"]
        })

      {agent, [d2]} = apply_result(agent, completed_1)

      completed_2 =
        simulate_completion(d2, %{
          topic: "Test",
          research_summary: "Research findings..."
        })

      {agent, [d3]} = apply_result(agent, completed_2)

      completed_3 =
        simulate_completion(d3, %{
          topic: "Test",
          outline: ["Section 1", "Section 2"]
        })

      {_agent, directives_4} = apply_result(agent, completed_3)
      runnables_4 = extract_execute_runnables(directives_4)

      assert length(runnables_4) == 1
      [d4] = runnables_4
      assert d4.target == {:child, :drafter}
    end
  end

  # -- build_directive Target Tests --------------------------------------------

  describe "build_directive target routing" do
    test "local ActionNode produces :local target" do
      node = ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1}, name: :add)
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {_agent, [directive]} = feed(agent, %{value: 5})
      assert directive.target == :local
    end

    test "delegated ActionNode produces {:child, tag} target" do
      node = ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1}, name: :add, executor: {:child, :worker})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {_agent, [directive]} = feed(agent, %{value: 5})
      assert directive.target == {:child, :worker}
    end
  end

  # -- Strategy Child Dispatch Tests -------------------------------------------

  describe "handle_child_dispatch" do
    test "emits SpawnAgent directive and tracks assignment" do
      node = ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1}, name: :add, executor: {:child, :worker})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow, child_modules: %{worker: Jido.RunicTest.TestAgent})

      {agent, [directive]} = feed(agent, %{value: 5})
      runnable_id = directive.runnable_id

      {agent, spawn_directives} =
        child_dispatch(agent, %{
          tag: :worker,
          runnable_id: runnable_id,
          runnable: directive.runnable,
          executor: {:child, :worker}
        })

      assert [%Jido.Agent.Directive.SpawnAgent{tag: :worker}] = spawn_directives

      strat = get_strat(agent)
      assert strat.child_assignments[:worker] == runnable_id
      assert strat.runnable_to_child[runnable_id] == :worker
    end

    test "uses module from executor tuple {:child, tag, module}" do
      node =
        ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1},
          name: :add,
          executor: {:child, :worker, Jido.RunicTest.TestAgent}
        )

      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {agent, [directive]} = feed(agent, %{value: 5})

      {_agent, spawn_directives} =
        child_dispatch(agent, %{
          tag: :worker,
          runnable_id: directive.runnable_id,
          runnable: directive.runnable,
          executor: {:child, :worker, Jido.RunicTest.TestAgent}
        })

      assert [%Jido.Agent.Directive.SpawnAgent{tag: :worker}] = spawn_directives
    end

    test "no-op when child module is unknown" do
      node = ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1}, name: :add, executor: {:child, :unknown})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {agent, [directive]} = feed(agent, %{value: 5})

      {_agent, directives} =
        child_dispatch(agent, %{
          tag: :unknown,
          runnable_id: directive.runnable_id,
          runnable: directive.runnable,
          executor: {:child, :unknown}
        })

      assert directives == []
    end
  end

  # -- Strategy Child Started Tests --------------------------------------------

  describe "handle_child_started" do
    test "emits work signal to child pid" do
      node = ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1}, name: :add, executor: {:child, :worker})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow, child_modules: %{worker: Jido.RunicTest.TestAgent})

      {agent, [directive]} = feed(agent, %{value: 5})
      runnable_id = directive.runnable_id

      {agent, _} =
        child_dispatch(agent, %{
          tag: :worker,
          runnable_id: runnable_id,
          runnable: directive.runnable,
          executor: {:child, :worker}
        })

      fake_pid = self()

      {_agent, emit_directives} =
        child_started(agent, %{
          tag: :worker,
          pid: fake_pid,
          parent_id: "parent-1",
          child_id: "child-1",
          child_module: Jido.RunicTest.TestAgent,
          meta: %{}
        })

      assert [%Jido.Agent.Directive.Emit{signal: signal}] = emit_directives
      assert signal.type == "runic.child.execute"
      assert signal.data.tag == :worker
      assert signal.data.runnable_id == runnable_id
    end

    test "no-op when tag has no assignment" do
      workflow = Workflow.new(name: :test)
      agent = make_agent(workflow)

      {_agent, directives} =
        child_started(agent, %{
          tag: :unknown,
          pid: self(),
          parent_id: "p1",
          child_id: "c1",
          child_module: nil,
          meta: %{}
        })

      assert directives == []
    end
  end

  # -- Child Result Cleans Up Assignments --------------------------------------

  describe "child assignment cleanup on apply_result" do
    test "clears child_assignments and runnable_to_child on completion" do
      node = ActionNode.new(Jido.RunicTest.Actions.Add, %{amount: 1}, name: :add, executor: {:child, :worker})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow, child_modules: %{worker: Jido.RunicTest.TestAgent})

      {agent, [directive]} = feed(agent, %{value: 5})
      runnable_id = directive.runnable_id

      {agent, _} =
        child_dispatch(agent, %{
          tag: :worker,
          runnable_id: runnable_id,
          runnable: directive.runnable,
          executor: {:child, :worker}
        })

      strat = get_strat(agent)
      assert strat.child_assignments[:worker] == runnable_id

      completed = simulate_completion(directive, %{value: 6})
      {agent, _} = apply_result(agent, completed)

      strat = get_strat(agent)
      assert strat.child_assignments == %{}
      assert strat.runnable_to_child == %{}
    end
  end

  # -- End-to-End Strategy-Level Test ------------------------------------------

  describe "end-to-end strategy-level delegation" do
    test "simulates full pipeline with local and delegated nodes" do
      workflow = DelegatingOrchestrator.build_workflow()

      agent =
        make_agent(workflow,
          child_modules: %{
            drafter: DrafterAgent,
            editor: EditorAgent
          }
        )

      # Step 1: Feed topic — dispatches PlanQueries (local)
      {agent, [d1]} = feed(agent, %{topic: "Multi-Agent"})
      assert %ExecuteRunnable{target: :local} = d1

      # PlanQueries completes
      completed_1 =
        simulate_completion(d1, %{
          topic: "Multi-Agent",
          queries: ["query 1", "query 2"],
          outline_seed: ["Intro", "Body"]
        })

      {agent, directives_2} = apply_result(agent, completed_1)
      [d2] = extract_execute_runnables(directives_2)
      assert d2.target == :local

      # SimulateSearch completes
      completed_2 =
        simulate_completion(d2, %{
          topic: "Multi-Agent",
          research_summary: "Detailed research about multi-agent systems..."
        })

      {agent, directives_3} = apply_result(agent, completed_2)
      [d3] = extract_execute_runnables(directives_3)
      assert d3.target == :local

      # BuildOutline completes
      completed_3 =
        simulate_completion(d3, %{
          topic: "Multi-Agent",
          outline: ["Section 1: Introduction", "Section 2: Architecture"]
        })

      {agent, directives_4} = apply_result(agent, completed_3)
      [d4] = extract_execute_runnables(directives_4)

      # DraftArticle should be delegated to :drafter
      assert d4.target == {:child, :drafter}
      assert get_strat(agent).status == :running

      # Simulate child dispatch → spawn → started → execute → result
      {agent, spawn_directives} =
        child_dispatch(agent, %{
          tag: :drafter,
          runnable_id: d4.runnable_id,
          runnable: d4.runnable,
          executor: {:child, :drafter}
        })

      assert [%Jido.Agent.Directive.SpawnAgent{tag: :drafter}] = spawn_directives

      {agent, [emit]} =
        child_started(agent, %{
          tag: :drafter,
          pid: self(),
          parent_id: "parent",
          child_id: "drafter-1",
          child_module: DrafterAgent,
          meta: %{}
        })

      assert %Jido.Agent.Directive.Emit{} = emit

      # Simulate child completing DraftArticle
      completed_4 =
        simulate_runnable_completion(d4.runnable, %{
          topic: "Multi-Agent",
          draft_markdown: "# Multi-Agent Systems\n\nDraft content..."
        })

      {agent, directives_5} = apply_result(agent, completed_4)
      [d5] = extract_execute_runnables(directives_5)

      # EditAndAssemble should be delegated to :editor
      assert d5.target == {:child, :editor}

      # Simulate editor child lifecycle
      {agent, _} =
        child_dispatch(agent, %{
          tag: :editor,
          runnable_id: d5.runnable_id,
          runnable: d5.runnable,
          executor: {:child, :editor}
        })

      {agent, _} =
        child_started(agent, %{
          tag: :editor,
          pid: self(),
          parent_id: "parent",
          child_id: "editor-1",
          child_module: EditorAgent,
          meta: %{}
        })

      # Simulate editor completing
      completed_5 =
        simulate_runnable_completion(d5.runnable, %{
          markdown: "# Multi-Agent Systems\n\nFinal polished content...",
          quality_score: 0.9
        })

      {agent, final_directives} = apply_result(agent, completed_5)

      strat = get_strat(agent)
      assert strat.status == :success
      assert strat.child_assignments == %{}
      assert strat.runnable_to_child == %{}

      productions = Workflow.raw_productions(strat.workflow)
      assert length(productions) >= 1

      emit_directives =
        Enum.filter(final_directives, fn
          %Jido.Agent.Directive.Emit{} -> true
          _ -> false
        end)

      assert length(emit_directives) >= 1
    end
  end

  # -- Article Extraction Tests ------------------------------------------------

  describe "article/1" do
    test "extracts markdown from productions" do
      result = %{productions: [%{markdown: "# Hello", quality_score: 0.85}]}
      assert %{markdown: "# Hello"} = DelegatingOrchestrator.article(result)
    end

    test "returns nil when no markdown production exists" do
      result = %{productions: [%{topic: "Test"}]}
      assert DelegatingOrchestrator.article(result) == nil
    end
  end

  # -- Signal Routes Tests -----------------------------------------------------

  describe "signal routes for child delegation" do
    test "includes child dispatch and child started routes" do
      routes = Strategy.signal_routes(%{})

      assert {"runic.child.dispatch", {:strategy_cmd, :runic_child_dispatch}} in routes
      assert {"jido.agent.child.started", {:strategy_cmd, :runic_child_started}} in routes
    end
  end

  # -- Init Tests --------------------------------------------------------------

  describe "init with child_modules" do
    test "stores child_modules in strategy state" do
      modules = %{drafter: DrafterAgent, editor: EditorAgent}
      workflow = Workflow.new(name: :test)
      agent = make_agent(workflow, child_modules: modules)

      strat = get_strat(agent)
      assert strat.child_modules == modules
      assert strat.child_assignments == %{}
      assert strat.runnable_to_child == %{}
    end
  end
end
