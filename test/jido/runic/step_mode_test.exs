defmodule Jido.Runic.StepModeTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.Strategy
  alias Jido.Runic.ActionNode
  alias Jido.Runic.Directive.ExecuteRunnable
  alias Jido.Runic.Introspection
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Runic.Workflow.Invokable

  alias Jido.RunicTest.Actions.{Add, Double, Fail}

  # -- Helpers -----------------------------------------------------------------

  defp make_agent(workflow, opts \\ []) do
    strategy_opts = [workflow: workflow] ++ opts
    ctx = %{strategy_opts: strategy_opts}

    agent = %Jido.Agent{
      id: "step-test-#{System.unique_integer([:positive])}",
      name: "test",
      description: "test",
      schema: [],
      state: %{}
    }

    {agent, _} = Strategy.init(agent, ctx)
    agent
  end

  defp get_strat(agent), do: StratState.get(agent)

  defp feed(agent, data) do
    instruction = %Jido.Instruction{action: :runic_feed_signal, params: %{data: data}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp step(agent) do
    instruction = %Jido.Instruction{action: :runic_step, params: %{}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp resume(agent) do
    instruction = %Jido.Instruction{action: :runic_resume, params: %{}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp set_mode(agent, mode) do
    instruction = %Jido.Instruction{action: :runic_set_mode, params: %{mode: mode}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp apply_result(agent, runnable) do
    instruction = %Jido.Instruction{action: :runic_apply_result, params: %{runnable: runnable}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
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

  # -- Tests -------------------------------------------------------------------

  describe "init with step mode" do
    test "initializes with execution_mode: :step" do
      agent = make_agent(single_node_workflow(), execution_mode: :step)
      strat = get_strat(agent)
      assert strat.execution_mode == :step
      assert strat.step_history == []
      assert strat.held_runnables == []
    end

    test "defaults to execution_mode: :auto" do
      agent = make_agent(single_node_workflow())
      strat = get_strat(agent)
      assert strat.execution_mode == :auto
    end
  end

  describe "feed in step mode" do
    test "pauses after feed instead of dispatching" do
      agent = make_agent(single_node_workflow(), execution_mode: :step)
      {agent, directives} = feed(agent, %{value: 5})

      assert directives == []
      strat = get_strat(agent)
      assert strat.status == :paused
      assert length(strat.held_runnables) == 1
    end

    test "pipeline: pauses with first node held" do
      agent = make_agent(pipeline_workflow(), execution_mode: :step)
      {agent, directives} = feed(agent, %{value: 5})

      assert directives == []
      strat = get_strat(agent)
      assert strat.status == :paused
      assert length(strat.held_runnables) == 1
    end
  end

  describe "step command" do
    test "dispatches held runnables" do
      agent = make_agent(single_node_workflow(), execution_mode: :step)
      {agent, []} = feed(agent, %{value: 5})

      {agent, directives} = step(agent)
      assert [%ExecuteRunnable{}] = directives
      strat = get_strat(agent)
      assert strat.status == :running
      assert strat.held_runnables == []
    end

    test "step with no held runnables is a no-op" do
      agent = make_agent(single_node_workflow(), execution_mode: :step)
      {_agent, directives} = step(agent)
      assert directives == []
    end

    test "full pipeline step-through" do
      agent = make_agent(pipeline_workflow(), execution_mode: :step)

      # Feed
      {agent, []} = feed(agent, %{value: 5})
      assert get_strat(agent).status == :paused

      # Step 1: dispatch add node
      {agent, [d1]} = step(agent)
      assert get_strat(agent).status == :running

      # Execute and apply result
      executed1 = execute_directive(d1)
      assert executed1.status == :completed
      {agent, mid_directives} = apply_result(agent, executed1)

      strat = get_strat(agent)

      # Step history recorded
      assert length(strat.step_history) == 1
      [step1] = strat.step_history
      assert step1.node == :add
      assert step1.status == :completed
      assert step1.input == %{value: 5}
      assert step1.output == %{value: 6}

      # After first node, either paused with held runnables or success with productions
      case strat.status do
        :paused ->
          assert length(strat.held_runnables) == 1
          assert mid_directives == []

          # Step 2: dispatch double node
          {agent, [d2]} = step(agent)
          assert get_strat(agent).status == :running

          executed2 = execute_directive(d2)
          assert executed2.status == :completed
          {agent, final_directives} = apply_result(agent, executed2)

          strat = get_strat(agent)
          assert strat.status == :success
          assert length(strat.step_history) == 2

          emit = Enum.find(final_directives, &match?(%Jido.Agent.Directive.Emit{}, &1))
          assert emit.signal.data == %{value: 12}

        :success ->
          # Workflow produced intermediate result; held runnables still present
          assert length(strat.held_runnables) >= 1

          # Step 2: dispatch double node
          {agent, [d2]} = step(agent)

          executed2 = execute_directive(d2)
          assert executed2.status == :completed
          {agent, final_directives} = apply_result(agent, executed2)

          strat = get_strat(agent)
          assert strat.status == :success
          assert length(strat.step_history) == 2

          emit = Enum.find(final_directives, &match?(%Jido.Agent.Directive.Emit{}, &1))
          assert emit != nil
      end
    end
  end

  describe "resume command" do
    test "switches to auto mode and dispatches held runnables" do
      agent = make_agent(pipeline_workflow(), execution_mode: :step)
      {agent, []} = feed(agent, %{value: 5})

      assert get_strat(agent).status == :paused
      assert get_strat(agent).execution_mode == :step

      {agent, directives} = resume(agent)
      strat = get_strat(agent)

      assert strat.execution_mode == :auto
      assert strat.held_runnables == []
      assert [%ExecuteRunnable{}] = directives
      assert strat.status == :running
    end
  end

  describe "set_mode command" do
    test "switches to step mode" do
      agent = make_agent(single_node_workflow())
      {agent, []} = set_mode(agent, :step)
      assert get_strat(agent).execution_mode == :step
    end

    test "switches back to auto mode" do
      agent = make_agent(single_node_workflow(), execution_mode: :step)
      {agent, []} = set_mode(agent, :auto)
      assert get_strat(agent).execution_mode == :auto
    end
  end

  describe "failure in step mode" do
    test "records failed step and transitions to failure" do
      agent = make_agent(failing_workflow(), execution_mode: :step)
      {agent, []} = feed(agent, %{reason: "boom"})

      assert get_strat(agent).status == :paused

      {agent, [d1]} = step(agent)
      executed = execute_directive(d1)
      assert executed.status == :failed

      {agent, []} = apply_result(agent, executed)
      strat = get_strat(agent)

      assert strat.status == :failure
      assert length(strat.step_history) == 1
      [step1] = strat.step_history
      assert step1.status == :failed
      assert step1.error != nil
    end
  end

  describe "snapshot with step mode" do
    test "includes step mode details" do
      agent = make_agent(pipeline_workflow(), execution_mode: :step)
      {agent, []} = feed(agent, %{value: 5})

      snap = Strategy.snapshot(agent, %{})
      assert snap.status == :paused
      assert snap.details.execution_mode == :step
      assert snap.details.held_count == 1
      assert snap.details.step_history == []
    end

    test "includes step history after stepping" do
      agent = make_agent(pipeline_workflow(), execution_mode: :step)
      {agent, []} = feed(agent, %{value: 5})
      {agent, [d1]} = step(agent)
      executed = execute_directive(d1)
      {agent, _directives} = apply_result(agent, executed)

      snap = Strategy.snapshot(agent, %{})
      assert length(snap.details.step_history) == 1
      assert snap.details.current_node == :add
    end
  end

  describe "introspection integration" do
    test "annotated_graph shows status per node" do
      agent = make_agent(pipeline_workflow(), execution_mode: :step)
      strat = get_strat(agent)
      graph = Introspection.annotated_graph(strat.workflow, strat)

      assert Enum.all?(graph.nodes, fn n -> n.status == :idle end)

      {agent, []} = feed(agent, %{value: 5})
      {agent, [d1]} = step(agent)
      executed = execute_directive(d1)
      {agent, _directives} = apply_result(agent, executed)
      strat = get_strat(agent)

      graph = Introspection.annotated_graph(strat.workflow, strat)

      add_node = Enum.find(graph.nodes, &(&1.name == :add))

      assert add_node.status == :completed
    end

    test "node_map returns all nodes with metadata" do
      workflow = pipeline_workflow()
      node_map = Introspection.node_map(workflow)

      assert Map.has_key?(node_map, :add)
      assert Map.has_key?(node_map, :double)

      add_info = node_map[:add]
      assert add_info.type == :action_node
      assert add_info.action_mod == Add
    end

    test "execution_summary reflects workflow state" do
      agent = make_agent(single_node_workflow(), execution_mode: :step)
      {agent, []} = feed(agent, %{value: 5})
      strat = get_strat(agent)
      summary = Introspection.execution_summary(strat.workflow)

      assert summary.total_nodes >= 1
      assert summary.facts_produced >= 1
      assert summary.satisfied == false
    end
  end

  describe "signal routes" do
    test "includes step mode routes" do
      routes = Strategy.signal_routes(%{})
      assert {"runic.step", {:strategy_cmd, :runic_step}} in routes
      assert {"runic.resume", {:strategy_cmd, :runic_resume}} in routes
      assert {"runic.set_mode", {:strategy_cmd, :runic_set_mode}} in routes
    end
  end

  describe "action_spec" do
    test "returns specs for step mode actions" do
      assert Strategy.action_spec(:runic_step) != nil
      assert Strategy.action_spec(:runic_resume) != nil
      assert Strategy.action_spec(:runic_set_mode) != nil
    end
  end
end
