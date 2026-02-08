defmodule JidoRunic.StrategyTest do
  use ExUnit.Case, async: true

  alias JidoRunic.Strategy
  alias JidoRunic.Directive.ExecuteRunnable
  alias JidoRunicTest.TestAgents.SimpleAgent
  alias JidoRunicTest.TestActions.{AddOne, Double}
  alias JidoRunic.ActionNode
  alias Runic.Workflow
  alias Jido.Agent.Strategy.State, as: StratState

  defp build_workflow do
    node = ActionNode.new(AddOne)
    Workflow.new(:test_workflow) |> Workflow.add(node)
  end

  defp ctx, do: %{agent_module: SimpleAgent, strategy_opts: []}

  defp set_workflow_instruction(workflow) do
    %Jido.Instruction{action: :runic_set_workflow, params: %{workflow: workflow}}
  end

  defp feed_signal_instruction(data) do
    %Jido.Instruction{action: :runic_feed_signal, params: %{data: data}}
  end

  defp apply_result_instruction(runnable) do
    %Jido.Instruction{action: :runic_apply_result, params: %{runnable: runnable}}
  end

  describe "init/2" do
    test "initializes strategy state with default workflow" do
      agent = SimpleAgent.new()
      strat = StratState.get(agent)

      assert strat.workflow != nil
      assert strat.status == :idle
      assert strat.pending_runnables == %{}
    end

    test "is idempotent — second init preserves existing workflow" do
      agent = SimpleAgent.new()
      strat_before = StratState.get(agent)

      {agent2, []} = Strategy.init(agent, ctx())
      strat_after = StratState.get(agent2)

      assert strat_before.workflow == strat_after.workflow
    end
  end

  describe "cmd/3 with :runic_set_workflow" do
    test "replaces the workflow in strategy state" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      strat = StratState.get(agent)

      assert strat.workflow.name == :test_workflow
    end
  end

  describe "cmd/3 with :runic_feed_signal" do
    test "returns ExecuteRunnable directives for planned runnables" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, directives} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      assert length(directives) > 0
      assert Enum.all?(directives, &match?(%ExecuteRunnable{}, &1))

      strat = StratState.get(agent)
      assert strat.status == :running
      assert map_size(strat.pending_runnables) > 0
    end
  end

  describe "cmd/3 with :runic_apply_result" do
    test "applies completed runnables and emits productions" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, directives} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      assert [%ExecuteRunnable{} = exec_dir] = directives

      executed_runnable = Strategy.execute_runnable(exec_dir)

      {agent, emit_directives} =
        Strategy.cmd(agent, [apply_result_instruction(executed_runnable)], ctx())

      assert length(emit_directives) > 0

      assert Enum.all?(emit_directives, fn
               %Jido.Agent.Directive.Emit{} -> true
               _ -> false
             end)

      strat = StratState.get(agent)
      assert strat.status == :satisfied
      assert strat.pending_runnables == %{}
    end

    test "production values contain action results" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, [exec_dir]} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      executed = Strategy.execute_runnable(exec_dir)

      {_agent, emit_directives} =
        Strategy.cmd(agent, [apply_result_instruction(executed)], ctx())

      signals = Enum.map(emit_directives, & &1.signal)
      signal_data = Enum.map(signals, & &1.data)

      assert %{value: 6} in signal_data
    end
  end

  describe "end-to-end workflow" do
    test "feed signal -> execute -> apply result -> productions" do
      node = ActionNode.new(AddOne)
      workflow = Workflow.new(:e2e) |> Workflow.add(node)

      agent = SimpleAgent.new()
      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())

      {agent, exec_directives} =
        Strategy.cmd(agent, [feed_signal_instruction(%{value: 10})], ctx())

      assert [%ExecuteRunnable{} = dir] = exec_directives
      assert dir.runnable.status == :pending

      executed = Strategy.execute_runnable(dir)
      assert executed.status == :completed

      {final_agent, emit_directives} =
        Strategy.cmd(agent, [apply_result_instruction(executed)], ctx())

      assert length(emit_directives) > 0

      strat = StratState.get(final_agent)
      assert strat.status == :satisfied

      signal_data = Enum.map(emit_directives, & &1.signal.data)
      assert %{value: 11} in signal_data
    end
  end

  describe "snapshot/2" do
    test "returns snapshot with idle status initially" do
      agent = SimpleAgent.new()
      snap = Strategy.snapshot(agent, ctx())

      assert snap.status == :idle
      assert snap.done? == false
    end

    test "returns snapshot with running status after feed" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, _directives} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 1})], ctx())

      snap = Strategy.snapshot(agent, ctx())
      assert snap.status == :running
      assert snap.done? == false
      assert snap.details.pending_count > 0
    end
  end

  describe "multi-step workflow" do
    test "chained AddOne → Double walks through full strategy loop" do
      add_node = ActionNode.new(AddOne, %{}, name: :add)
      double_node = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:chain)
        |> Workflow.add(add_node)
        |> Workflow.add(double_node, to: :add)

      agent = SimpleAgent.new()
      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())

      {agent, exec_directives} =
        Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      assert [%ExecuteRunnable{} = first_dir] = exec_directives

      first_executed = Strategy.execute_runnable(first_dir)
      assert first_executed.status == :completed

      {agent, next_directives} =
        Strategy.cmd(agent, [apply_result_instruction(first_executed)], ctx())

      exec_dirs = Enum.filter(next_directives, &match?(%ExecuteRunnable{}, &1))
      assert length(exec_dirs) > 0

      {agent, final_directives} =
        Enum.reduce(exec_dirs, {agent, []}, fn dir, {acc_agent, acc_dirs} ->
          executed = Strategy.execute_runnable(dir)
          {new_agent, dirs} = Strategy.cmd(acc_agent, [apply_result_instruction(executed)], ctx())
          {new_agent, acc_dirs ++ dirs}
        end)

      emit_dirs = Enum.filter(final_directives, &match?(%Jido.Agent.Directive.Emit{}, &1))
      assert length(emit_dirs) > 0

      signal_data = Enum.map(emit_dirs, & &1.signal.data)
      assert %{value: 12} in signal_data

      strat = StratState.get(agent)
      assert strat.status == :satisfied
      assert strat.pending_runnables == %{}
    end
  end

  describe "fan-out workflow" do
    test "single root branches to two parallel ActionNodes" do
      root = ActionNode.new(AddOne, %{}, name: :root_add)
      double_branch = ActionNode.new(Double, %{}, name: :double_branch)
      add_branch = ActionNode.new(AddOne, %{}, name: :add_branch)

      workflow =
        Workflow.new(:fan_out)
        |> Workflow.add(root)
        |> Workflow.add(double_branch, to: :root_add)
        |> Workflow.add(add_branch, to: :root_add)

      agent = SimpleAgent.new()
      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())

      {agent, exec_directives} =
        Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      assert [%ExecuteRunnable{} = root_dir] = exec_directives

      root_executed = Strategy.execute_runnable(root_dir)

      {agent, branch_directives} =
        Strategy.cmd(agent, [apply_result_instruction(root_executed)], ctx())

      branch_exec_dirs = Enum.filter(branch_directives, &match?(%ExecuteRunnable{}, &1))
      assert length(branch_exec_dirs) == 2

      {agent, final_directives} =
        Enum.reduce(branch_exec_dirs, {agent, []}, fn dir, {acc_agent, acc_dirs} ->
          executed = Strategy.execute_runnable(dir)
          {new_agent, dirs} = Strategy.cmd(acc_agent, [apply_result_instruction(executed)], ctx())
          {new_agent, acc_dirs ++ dirs}
        end)

      emit_dirs = Enum.filter(final_directives, &match?(%Jido.Agent.Directive.Emit{}, &1))
      assert length(emit_dirs) > 0

      signal_data = Enum.map(emit_dirs, & &1.signal.data)
      assert %{value: 12} in signal_data
      assert %{value: 7} in signal_data

      strat = StratState.get(agent)
      assert strat.status == :satisfied
      assert strat.pending_runnables == %{}
    end
  end

  describe "failed runnable handling" do
    alias Runic.Workflow.Runnable

    test "applying a failed runnable emits a failure signal" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, [%ExecuteRunnable{} = exec_dir]} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      failed_runnable = Runnable.fail(exec_dir.runnable, "test failure")

      {_agent, directives} =
        Strategy.cmd(agent, [apply_result_instruction(failed_runnable)], ctx())

      assert [%Jido.Agent.Directive.Emit{signal: signal}] = directives
      assert signal.type == "runic.runnable.failed"
      assert signal.data.error == "test failure"
      assert signal.data.runnable_id == failed_runnable.id
    end

    test "failed runnable sets status correctly" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, [%ExecuteRunnable{} = exec_dir]} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      failed_runnable = Runnable.fail(exec_dir.runnable, "test failure")

      {agent, _directives} =
        Strategy.cmd(agent, [apply_result_instruction(failed_runnable)], ctx())

      strat = StratState.get(agent)
      assert strat.status == :failed
      assert strat.pending_runnables == %{}
    end
  end

  describe "signal_routes/1" do
    test "signal_routes returns expected route map" do
      routes = Strategy.signal_routes(%{})

      assert {"runic.feed", {:strategy_cmd, :runic_feed_signal}} in routes
      assert {"runic.runnable.completed", {:strategy_cmd, :runic_apply_result}} in routes
      assert {"runic.runnable.failed", {:strategy_cmd, :runic_handle_failure}} in routes
    end

    test "route_signal matches exact type" do
      assert Strategy.route_signal(%{type: "runic.feed"}) == :runic_feed_signal
      assert Strategy.route_signal(%{type: "runic.runnable.completed"}) == :runic_apply_result
      assert Strategy.route_signal(%{type: "runic.runnable.failed"}) == :runic_handle_failure
    end

    test "route_signal matches prefix" do
      assert Strategy.route_signal(%{type: "runic.feed.my_event"}) == :runic_feed_signal
      assert Strategy.route_signal(%{type: "runic.runnable.completed.sub"}) == :runic_apply_result
    end

    test "route_signal returns nil for unknown type" do
      assert Strategy.route_signal(%{type: "unknown.signal"}) == nil
      assert Strategy.route_signal(%{type: ""}) == nil
      assert Strategy.route_signal(%{}) == nil
    end
  end

  describe "tick/2" do
    test "tick is no-op when idle (no workflow set)" do
      agent = SimpleAgent.new()
      {agent2, directives} = Strategy.tick(agent, ctx())

      assert directives == []
      assert agent2 == agent
    end

    test "tick is no-op for satisfied status" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, [exec_dir]} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      executed = Strategy.execute_runnable(exec_dir)
      {agent, _emit} = Strategy.cmd(agent, [apply_result_instruction(executed)], ctx())

      strat = StratState.get(agent)
      assert strat.status == :satisfied

      {agent2, directives} = Strategy.tick(agent, ctx())
      assert directives == []
      assert agent2 == agent
    end

    test "tick is no-op for failed status" do
      alias Runic.Workflow.Runnable

      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, [exec_dir]} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      failed_runnable = Runnable.fail(exec_dir.runnable, "test failure")
      {agent, _} = Strategy.cmd(agent, [apply_result_instruction(failed_runnable)], ctx())

      strat = StratState.get(agent)
      assert strat.status == :failed

      {agent2, directives} = Strategy.tick(agent, ctx())
      assert directives == []
      assert agent2 == agent
    end

    test "tick returns no directives when running but no new work available" do
      agent = SimpleAgent.new()
      workflow = build_workflow()

      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())
      {agent, [%ExecuteRunnable{}]} = Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      strat = StratState.get(agent)
      assert strat.status == :running

      {_agent, directives} = Strategy.tick(agent, ctx())
      assert directives == []
    end

    test "tick dispatches available runnables when running" do
      add_node = ActionNode.new(AddOne, %{}, name: :add)
      double_node = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:tick_chain)
        |> Workflow.add(add_node)
        |> Workflow.add(double_node, to: :add)

      agent = SimpleAgent.new()
      {agent, []} = Strategy.cmd(agent, [set_workflow_instruction(workflow)], ctx())

      {agent, [%ExecuteRunnable{} = first_dir]} =
        Strategy.cmd(agent, [feed_signal_instruction(%{value: 5})], ctx())

      strat = StratState.get(agent)
      assert strat.status == :running

      first_executed = Strategy.execute_runnable(first_dir)

      strat = StratState.get(agent)
      workflow_updated = Workflow.apply_runnable(strat.workflow, first_executed)

      agent =
        StratState.put(agent, %{
          strat
          | workflow: workflow_updated,
            pending_runnables: Map.delete(strat.pending_runnables, first_executed.id)
        })

      assert Workflow.is_runnable?(workflow_updated)

      {agent_after_tick, tick_directives} = Strategy.tick(agent, ctx())
      assert length(tick_directives) > 0
      assert Enum.all?(tick_directives, &match?(%ExecuteRunnable{}, &1))

      strat_after = StratState.get(agent_after_tick)
      assert map_size(strat_after.pending_runnables) > 0
    end
  end

  describe "unknown instructions" do
    test "are silently ignored" do
      agent = SimpleAgent.new()
      instr = %Jido.Instruction{action: :unknown_action, params: %{}}

      {agent2, directives} = Strategy.cmd(agent, [instr], ctx())
      assert directives == []
      assert agent2 == agent
    end
  end
end
