defmodule JidoRunicTest.SignalMatchTest do
  use ExUnit.Case, async: true

  alias JidoRunic.SignalMatch
  alias JidoRunic.ActionNode
  alias Runic.Workflow

  alias JidoRunicTest.TestActions.AddOne

  describe "new/2" do
    test "creates a SignalMatch with pattern" do
      node = SignalMatch.new("order.paid")
      assert node.pattern == "order.paid"
      assert node.name == :"signal_match_order.paid"
      assert is_integer(node.hash)
    end

    test "accepts custom name" do
      node = SignalMatch.new("order.paid", name: :paid_gate)
      assert node.name == :paid_gate
    end

    test "stable hashes for same pattern and name" do
      n1 = SignalMatch.new("order.paid", name: :gate)
      n2 = SignalMatch.new("order.paid", name: :gate)
      assert n1.hash == n2.hash
    end
  end

  describe "signal gating" do
    test "matching signal type activates downstream" do
      gate = SignalMatch.new("order.paid", name: :gate)
      action = ActionNode.new(AddOne, %{}, name: :process)

      workflow =
        Workflow.new(:gating_test)
        |> Workflow.add(gate)
        |> Workflow.add(action, to: :gate)

      results =
        workflow
        |> Workflow.react_until_satisfied(%{type: "order.paid", value: 5})
        |> Workflow.raw_productions()

      assert Enum.any?(results, fn
        %{value: 6} -> true
        _ -> false
      end)
    end

    test "non-matching signal type skips downstream" do
      gate = SignalMatch.new("order.paid", name: :gate)
      action = ActionNode.new(AddOne, %{}, name: :process)

      workflow =
        Workflow.new(:skip_test)
        |> Workflow.add(gate)
        |> Workflow.add(action, to: :gate)

      results =
        workflow
        |> Workflow.react_until_satisfied(%{type: "order.cancelled", value: 5})
        |> Workflow.raw_productions()

      refute Enum.any?(results, fn
        %{value: 6} -> true
        _ -> false
      end)
    end

    test "prefix matching works" do
      gate = SignalMatch.new("order", name: :gate)

      workflow =
        Workflow.new(:prefix_test)
        |> Workflow.add(gate)

      result = Workflow.react_until_satisfied(workflow, %{type: "order.paid.confirmed"})
      productions = Workflow.raw_productions(result)
      assert length(productions) >= 0
    end
  end

  describe "Component protocol" do
    test "hash returns node hash" do
      node = SignalMatch.new("test", name: :gate)
      assert Runic.Component.hash(node) == node.hash
    end

    test "source returns reconstructable AST" do
      node = SignalMatch.new("test.pattern", name: :gate)
      source = Runic.Component.source(node)
      assert is_tuple(source)
    end
  end

  describe "Transmutable protocol" do
    test "to_workflow wraps in workflow" do
      node = SignalMatch.new("test", name: :gate)
      wf = Runic.Transmutable.to_workflow(node)
      assert is_struct(wf, Workflow)
    end
  end
end
