defmodule Jido.RunicTest.ChildWorker do
  use ExUnit.Case, async: true

  alias Jido.Runic.ChildWorker
  alias Jido.Runic.ChildWorker.ExecuteAction
  alias Jido.Runic.Strategy
  alias Jido.Runic.ActionNode
  alias Jido.Runic.Directive.ExecuteRunnable
  alias Jido.Agent.Strategy.State, as: StratState
  alias Runic.Workflow
  alias Jido.RunicTest.Actions.Add

  defp make_agent(workflow, opts \\ []) do
    strategy_opts = [workflow: workflow] ++ opts
    ctx = %{strategy_opts: strategy_opts}

    agent = %Jido.Agent{
      id: "child-test-#{System.unique_integer([:positive])}",
      name: "child_test",
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

  defp child_dispatch(agent, params) do
    instruction = %Jido.Instruction{action: :runic_child_dispatch, params: params}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp child_started(agent, params) do
    instruction = %Jido.Instruction{action: :runic_child_started, params: params}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  describe "signal_routes/1" do
    test "returns the expected route tuple" do
      routes = ChildWorker.signal_routes(%{})

      assert [{"runic.child.execute", ChildWorker.ExecuteAction}] = routes
    end
  end

  describe "ExecuteAction" do
    test "successfully executes a runnable and returns {:ok, %{}, directives}" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add)
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {_agent, [directive]} = feed(agent, %{value: 5})
      runnable = directive.runnable

      context = %{state: %{}}

      result =
        ExecuteAction.run(
          %{runnable: runnable, runnable_id: runnable.id, tag: :worker},
          context
        )

      assert {:ok, %{}, directives} = result
      assert is_list(directives)
    end

    test "returns error on runnable ID mismatch" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add)
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {_agent, [directive]} = feed(agent, %{value: 5})
      runnable = directive.runnable

      context = %{state: %{}}
      wrong_id = :wrong_id

      result =
        ExecuteAction.run(
          %{runnable: runnable, runnable_id: wrong_id, tag: :worker},
          context
        )

      assert {:error, message} = result
      assert message =~ "Runnable ID mismatch"
    end
  end

  describe "build_directive/1 via Strategy" do
    test "ActionNode with executor: {:child, :drafter} produces {:child, :drafter} target" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add, executor: {:child, :drafter})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {_agent, [directive]} = feed(agent, %{value: 5})

      assert %ExecuteRunnable{target: {:child, :drafter}} = directive
    end

    test "ActionNode with executor: {:child, :drafter, SomeModule} produces {:child, :drafter} target" do
      node =
        ActionNode.new(Add, %{amount: 1},
          name: :add,
          executor: {:child, :drafter, Jido.RunicTest.TestAgent}
        )

      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow)

      {_agent, [directive]} = feed(agent, %{value: 5})

      assert %ExecuteRunnable{target: {:child, :drafter}} = directive
    end
  end

  describe "child_dispatch via Strategy.cmd" do
    test "dispatches with child_modules config - produces spawn_agent directive" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add, executor: {:child, :drafter})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow, child_modules: %{drafter: ChildWorker})

      {agent, [directive]} = feed(agent, %{value: 5})

      {agent, spawn_directives} =
        child_dispatch(agent, %{
          tag: :drafter,
          runnable_id: directive.runnable_id,
          runnable: directive.runnable,
          executor: {:child, :drafter}
        })

      assert [%Jido.Agent.Directive.SpawnAgent{tag: :drafter}] = spawn_directives

      strat = get_strat(agent)
      assert strat.child_assignments[:drafter] == directive.runnable_id
      assert strat.runnable_to_child[directive.runnable_id] == :drafter
    end

    test "no-op when child_module not found" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add, executor: {:child, :unknown})
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

  describe "child_started via Strategy.cmd" do
    test "emits work signal to child pid when assignment exists" do
      node = ActionNode.new(Add, %{amount: 1}, name: :add, executor: {:child, :drafter})
      workflow = Workflow.new(name: :test) |> Workflow.add(node)
      agent = make_agent(workflow, child_modules: %{drafter: ChildWorker})

      {agent, [directive]} = feed(agent, %{value: 5})
      runnable_id = directive.runnable_id

      {agent, _} =
        child_dispatch(agent, %{
          tag: :drafter,
          runnable_id: runnable_id,
          runnable: directive.runnable,
          executor: {:child, :drafter}
        })

      {_agent, emit_directives} =
        child_started(agent, %{
          tag: :drafter,
          pid: self(),
          parent_id: "parent-1",
          child_id: "child-1",
          child_module: ChildWorker,
          meta: %{}
        })

      assert [%Jido.Agent.Directive.Emit{signal: signal}] = emit_directives
      assert signal.type == "runic.child.execute"
      assert signal.data.runnable_id == runnable_id
      assert signal.data.tag == :drafter
    end

    test "no-op when no assignment for tag" do
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
end
