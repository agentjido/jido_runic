defmodule Jido.RunicTest.RunnableExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.{ActionNode, RunnableExecution}
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Invokable, Runnable, CausalContext}

  alias Jido.RunicTest.Actions.{Add, Fail}
  alias Jido.RunicTest.Nodes.{RaisingNode, ThrowingNode}

  defp build_runnable(action_mod, params, input) do
    node = ActionNode.new(action_mod, params, name: :test_node)

    workflow =
      Workflow.new(name: :test)
      |> Workflow.add(node)

    fact = Fact.new(value: input)
    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    runnable
  end

  defp build_custom_runnable(node_struct) do
    fact = Fact.new(value: %{})
    ctx = CausalContext.new(node_hash: node_struct.hash, input_fact: fact)
    Runnable.new(node_struct, fact, ctx)
  end

  describe "execute/1" do
    test "successful execution returns completed runnable" do
      runnable = build_runnable(Add, %{amount: 1}, %{value: 5})
      executed = RunnableExecution.execute(runnable)
      assert executed.status == :completed
    end

    test "failed execution returns failed runnable" do
      runnable = build_runnable(Fail, %{}, %{reason: "boom"})
      executed = RunnableExecution.execute(runnable)
      assert executed.status == :failed
    end

    test "rescues exceptions and returns failed runnable" do
      runnable = build_custom_runnable(%RaisingNode{name: :raiser, hash: 12345})
      executed = RunnableExecution.execute(runnable)
      assert executed.status == :failed
      assert executed.error =~ "unexpected crash"
    end

    test "catches throws and returns failed runnable" do
      runnable = build_custom_runnable(%ThrowingNode{name: :thrower, hash: 67890})
      executed = RunnableExecution.execute(runnable)
      assert executed.status == :failed
      assert executed.error =~ "Caught throw"
      assert executed.error =~ "unexpected_throw"
    end
  end

  describe "completion_signal/2" do
    test "completed runnable produces completed signal type" do
      runnable = build_runnable(Add, %{amount: 1}, %{value: 5})
      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed)
      assert signal.type == "runic.runnable.completed"
    end

    test "failed runnable produces failed signal type" do
      runnable = build_runnable(Fail, %{}, %{reason: "boom"})
      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed)
      assert signal.type == "runic.runnable.failed"
    end

    test "skipped runnable produces completed signal type" do
      runnable = build_runnable(Add, %{amount: 1}, %{value: 5})
      skipped = Runnable.skip(runnable, fn workflow -> workflow end)
      signal = RunnableExecution.completion_signal(skipped)
      assert signal.type == "runic.runnable.completed"
    end

    test "default source is /runic/executor" do
      runnable = build_runnable(Add, %{amount: 1}, %{value: 5})
      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed)
      assert signal.source == "/runic/executor"
    end

    test "accepts custom source option" do
      runnable = build_runnable(Add, %{amount: 1}, %{value: 5})
      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed, source: "/my/custom/agent")
      assert signal.source == "/my/custom/agent"
    end

    test "signal data contains the runnable" do
      runnable = build_runnable(Add, %{amount: 1}, %{value: 5})
      executed = RunnableExecution.execute(runnable)
      signal = RunnableExecution.completion_signal(executed)
      assert signal.data.runnable == executed
    end
  end
end
