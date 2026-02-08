defmodule Jido.Runic.StrategyTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.Strategy
  alias Jido.Runic.ActionNode
  alias Jido.Runic.Directive.ExecuteRunnable
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Runic.Workflow.Invokable

  alias Jido.RunicTest.Actions.{Add, Double, Fail}

  # -- Helpers -----------------------------------------------------------------

  defp make_agent(workflow, opts \\ []) do
    strategy_opts = [workflow: workflow] ++ opts
    ctx = %{strategy_opts: strategy_opts}

    agent = %Jido.Agent{
      id: "test-#{System.unique_integer([:positive])}",
      name: "test",
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
    ctx = %{strategy_opts: []}
    Strategy.cmd(agent, [instruction], ctx)
  end

  defp apply_result(agent, runnable) do
    instruction = %Jido.Instruction{action: :runic_apply_result, params: %{runnable: runnable}}
    ctx = %{strategy_opts: []}
    Strategy.cmd(agent, [instruction], ctx)
  end

  defp execute_directive(%ExecuteRunnable{runnable: runnable}) do
    Invokable.execute(runnable.node, runnable)
  end

  defp single_node_workflow do
    node = ActionNode.new(Add, %{amount: 10}, name: :add)

    Workflow.new(name: :single)
    |> Workflow.add(node)
  end

  defp pipeline_workflow do
    add_node = ActionNode.new(Add, %{amount: 1}, name: :add)
    double_node = ActionNode.new(Double, %{}, name: :double)

    Workflow.new(name: :pipeline)
    |> Workflow.add(add_node)
    |> Workflow.add(double_node, to: :add)
  end

  defp failing_workflow do
    node = ActionNode.new(Fail, %{}, name: :fail)

    Workflow.new(name: :failing)
    |> Workflow.add(node)
  end

  # -- Init Tests --------------------------------------------------------------

  describe "init/2" do
    test "initializes with provided workflow" do
      workflow = single_node_workflow()
      agent = make_agent(workflow)
      strat = get_strat(agent)

      assert %Workflow{} = strat.workflow
      assert strat.status == :idle
      assert strat.pending == %{}
      assert strat.queued == []
      assert strat.max_concurrent == :infinity
    end

    test "initializes with workflow_fn" do
      workflow = single_node_workflow()
      ctx = %{strategy_opts: [workflow_fn: fn -> workflow end]}

      agent = %Jido.Agent{
        id: "test",
        name: "test",
        description: "test",
        schema: [],
        state: %{}
      }

      {agent, []} = Strategy.init(agent, ctx)
      strat = get_strat(agent)

      assert %Workflow{} = strat.workflow
    end

    test "initializes with max_concurrent option" do
      agent = make_agent(single_node_workflow(), max_concurrent: 2)
      strat = get_strat(agent)

      assert strat.max_concurrent == 2
    end

    test "is idempotent — does not overwrite existing strategy state" do
      workflow = single_node_workflow()
      agent = make_agent(workflow)

      different_workflow = pipeline_workflow()
      ctx = %{strategy_opts: [workflow: different_workflow]}
      {agent2, []} = Strategy.init(agent, ctx)

      assert get_strat(agent2).workflow == get_strat(agent).workflow
    end

    test "creates default workflow when none provided" do
      ctx = %{strategy_opts: []}

      agent = %Jido.Agent{
        id: "test",
        name: "test",
        description: "test",
        schema: [],
        state: %{}
      }

      {agent, []} = Strategy.init(agent, ctx)
      assert %Workflow{} = get_strat(agent).workflow
    end
  end

  # -- Signal Routes -----------------------------------------------------------

  describe "signal_routes/1" do
    test "routes feed, completed, failed, and set_workflow signals" do
      routes = Strategy.signal_routes(%{})

      assert {"runic.feed", {:strategy_cmd, :runic_feed_signal}} in routes
      assert {"runic.runnable.completed", {:strategy_cmd, :runic_apply_result}} in routes
      assert {"runic.runnable.failed", {:strategy_cmd, :runic_apply_result}} in routes
      assert {"runic.set_workflow", {:strategy_cmd, :runic_set_workflow}} in routes
    end

    test "completed and failed both route to :runic_apply_result" do
      routes = Strategy.signal_routes(%{})

      completed = Enum.find(routes, fn {type, _} -> type == "runic.runnable.completed" end)
      failed = Enum.find(routes, fn {type, _} -> type == "runic.runnable.failed" end)

      assert elem(completed, 1) == {:strategy_cmd, :runic_apply_result}
      assert elem(failed, 1) == {:strategy_cmd, :runic_apply_result}
    end
  end

  # -- Feed Signal Tests -------------------------------------------------------

  describe "cmd/3 — feed signal" do
    test "single-node workflow: feed produces one ExecuteRunnable directive" do
      agent = make_agent(single_node_workflow())
      {agent, directives} = feed(agent, %{value: 5})

      assert [%ExecuteRunnable{} = d] = directives
      assert d.runnable_id != nil
      assert d.runnable.status == :pending
      assert d.target == :local
      assert get_strat(agent).status == :running
    end

    test "feed with no matching nodes produces no directives" do
      empty_wf = Workflow.new(name: :empty)
      agent = make_agent(empty_wf)
      {agent, directives} = feed(agent, %{value: 5})

      assert directives == []
      assert get_strat(agent).status == :idle
    end

    test "pending map tracks dispatched runnables" do
      agent = make_agent(single_node_workflow())
      {agent, [directive]} = feed(agent, %{value: 5})

      strat = get_strat(agent)
      assert Map.has_key?(strat.pending, directive.runnable_id)
    end

    test "pipeline workflow: feed produces one directive for first node" do
      agent = make_agent(pipeline_workflow())
      {agent, directives} = feed(agent, %{value: 5})

      assert length(directives) == 1
      assert [%ExecuteRunnable{}] = directives
      assert get_strat(agent).status == :running
    end
  end

  # -- Apply Result (Completion) Tests -----------------------------------------

  describe "cmd/3 — apply result (completed)" do
    test "single-node: completion produces :success with production emit" do
      agent = make_agent(single_node_workflow())
      {agent, [directive]} = feed(agent, %{value: 5})

      executed = execute_directive(directive)
      assert executed.status == :completed

      {agent, result_directives} = apply_result(agent, executed)
      strat = get_strat(agent)

      assert strat.status == :success
      assert strat.pending == %{}

      emit_directives =
        Enum.filter(result_directives, fn
          %Jido.Agent.Directive.Emit{} -> true
          _ -> false
        end)

      assert length(emit_directives) >= 1

      signal = hd(emit_directives).signal
      assert signal.type == "runic.workflow.production"
      assert signal.data == %{value: 15}
    end

    test "pipeline: first completion triggers second node" do
      agent = make_agent(pipeline_workflow())
      {agent, [d1]} = feed(agent, %{value: 5})

      executed1 = execute_directive(d1)
      {agent, directives2} = apply_result(agent, executed1)

      new_runnables =
        Enum.filter(directives2, fn
          %ExecuteRunnable{} -> true
          _ -> false
        end)

      assert length(new_runnables) == 1
      assert get_strat(agent).status == :running
    end

    test "pipeline: full completion produces correct final result" do
      agent = make_agent(pipeline_workflow())

      # Feed input
      {agent, [d1]} = feed(agent, %{value: 5})

      # Execute first node (add 1: 5 → 6)
      executed1 = execute_directive(d1)
      {agent, directives2} = apply_result(agent, executed1)

      [d2] =
        Enum.filter(directives2, fn
          %ExecuteRunnable{} -> true
          _ -> false
        end)

      # Execute second node (double: 6 → 12)
      executed2 = execute_directive(d2)
      {agent, final_directives} = apply_result(agent, executed2)

      assert get_strat(agent).status == :success

      emit =
        Enum.find(final_directives, fn
          %Jido.Agent.Directive.Emit{} -> true
          _ -> false
        end)

      assert emit.signal.data == %{value: 12}
    end
  end

  # -- Apply Result (Failure) Tests --------------------------------------------

  describe "cmd/3 — apply result (failed)" do
    test "failed runnable injects error fact and transitions to :failure" do
      agent = make_agent(failing_workflow())
      {agent, [directive]} = feed(agent, %{reason: "boom"})

      executed = execute_directive(directive)
      assert executed.status == :failed

      {agent, _directives} = apply_result(agent, executed)
      strat = get_strat(agent)

      # No fallback branches, so workflow quiesces with no productions → :failure
      assert strat.status == :failure
      assert strat.pending == %{}
    end

    test "failed runnable is removed from pending" do
      agent = make_agent(failing_workflow())
      {agent, [directive]} = feed(agent, %{reason: "boom"})

      executed = execute_directive(directive)
      {agent, _directives} = apply_result(agent, executed)

      assert get_strat(agent).pending == %{}
    end
  end

  # -- Snapshot Tests ----------------------------------------------------------

  describe "snapshot/2" do
    test "idle agent produces idle snapshot" do
      agent = make_agent(single_node_workflow())
      snap = Strategy.snapshot(agent, %{})

      assert snap.status == :idle
      assert snap.done? == false
      assert snap.result == nil
    end

    test "running agent produces running snapshot" do
      agent = make_agent(single_node_workflow())
      {agent, _} = feed(agent, %{value: 5})
      snap = Strategy.snapshot(agent, %{})

      assert snap.status == :running
      assert snap.done? == false
      assert snap.details.pending_count == 1
    end

    test "completed agent produces success snapshot with result" do
      agent = make_agent(single_node_workflow())
      {agent, [directive]} = feed(agent, %{value: 5})
      executed = execute_directive(directive)
      {agent, _} = apply_result(agent, executed)

      snap = Strategy.snapshot(agent, %{})

      assert snap.status == :success
      assert snap.done? == true
      assert snap.result != nil
      assert %{value: 15} in snap.result
    end

    test "failed agent produces failure snapshot" do
      agent = make_agent(failing_workflow())
      {agent, [directive]} = feed(agent, %{reason: "boom"})
      executed = execute_directive(directive)
      {agent, _} = apply_result(agent, executed)

      snap = Strategy.snapshot(agent, %{})

      assert snap.status == :failure
      assert snap.done? == true
    end
  end

  # -- Set Workflow Tests ------------------------------------------------------

  describe "cmd/3 — set workflow" do
    test "replaces the active workflow" do
      agent = make_agent(single_node_workflow())
      new_wf = pipeline_workflow()

      instruction = %Jido.Instruction{
        action: :runic_set_workflow,
        params: %{workflow: new_wf}
      }

      {agent, []} = Strategy.cmd(agent, [instruction], %{strategy_opts: []})

      strat = get_strat(agent)
      assert strat.status == :idle
      assert strat.pending == %{}
    end
  end

  # -- Concurrency Control Tests -----------------------------------------------

  describe "concurrency control" do
    test "max_concurrent limits dispatched runnables" do
      add1 = ActionNode.new(Add, %{amount: 1}, name: :add1)
      add2 = ActionNode.new(Add, %{amount: 2}, name: :add2)
      add3 = ActionNode.new(Add, %{amount: 3}, name: :add3)

      workflow =
        Workflow.new(name: :fan)
        |> Workflow.add(add1)
        |> Workflow.add(add2)
        |> Workflow.add(add3)

      agent = make_agent(workflow, max_concurrent: 2)
      {agent, directives} = feed(agent, %{value: 1})

      assert length(directives) == 2
      strat = get_strat(agent)
      assert map_size(strat.pending) == 2
      assert length(strat.queued) == 1
    end

    test "tick drains queued runnables when slots are available" do
      add1 = ActionNode.new(Add, %{amount: 1}, name: :add1)
      add2 = ActionNode.new(Add, %{amount: 2}, name: :add2)
      add3 = ActionNode.new(Add, %{amount: 3}, name: :add3)

      workflow =
        Workflow.new(name: :fan)
        |> Workflow.add(add1)
        |> Workflow.add(add2)
        |> Workflow.add(add3)

      agent = make_agent(workflow, max_concurrent: 2)
      {agent, directives} = feed(agent, %{value: 1})

      assert length(directives) == 2
      strat = get_strat(agent)
      assert length(strat.queued) == 1

      # Manually clear pending and add queued items to simulate slot availability
      strat = %{strat | pending: %{}}
      agent = StratState.put(agent, strat)

      {_agent, tick_directives} = Strategy.tick(agent, %{})
      assert length(tick_directives) == 1
    end
  end

  # -- Tick Tests --------------------------------------------------------------

  describe "tick/2" do
    test "no-op when idle" do
      agent = make_agent(single_node_workflow())
      {agent2, directives} = Strategy.tick(agent, %{})

      assert directives == []
      assert get_strat(agent2).status == :idle
    end

    test "recovers stalled running workflow" do
      agent = make_agent(single_node_workflow())
      {agent, [_d]} = feed(agent, %{value: 5})

      # Manually clear pending to simulate a stalled state
      strat = get_strat(agent)
      agent = StratState.put(agent, %{strat | pending: %{}})

      {_agent, tick_directives} = Strategy.tick(agent, %{})

      assert is_list(tick_directives)
    end
  end

  # -- Directive Structure Tests -----------------------------------------------

  describe "ExecuteRunnable directive" do
    test "carries runnable_id, runnable, and target" do
      agent = make_agent(single_node_workflow())
      {_agent, [directive]} = feed(agent, %{value: 5})

      assert %ExecuteRunnable{} = directive
      assert is_integer(directive.runnable_id)
      assert directive.runnable.status == :pending
      assert directive.target == :local
    end

    test "executor target is :local for plain ActionNodes" do
      agent = make_agent(single_node_workflow())
      {_agent, [directive]} = feed(agent, %{value: 5})

      assert directive.target == :local
    end
  end

  # -- Action Spec Tests -------------------------------------------------------

  describe "action_spec/1" do
    test "returns spec for known actions" do
      assert Strategy.action_spec(:runic_feed_signal) != nil
      assert Strategy.action_spec(:runic_apply_result) != nil
      assert Strategy.action_spec(:runic_set_workflow) != nil
    end

    test "returns nil for unknown actions" do
      assert Strategy.action_spec(:unknown_action) == nil
    end
  end
end
