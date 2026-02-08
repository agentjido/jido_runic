defmodule JidoRunicTest.SerializationTest do
  use ExUnit.Case, async: true

  alias JidoRunic.ActionNode
  alias JidoRunic.SignalMatch
  alias Runic.Workflow

  alias JidoRunicTest.TestActions.{AddOne, Double}

  describe "ActionNode round-trip" do
    test "ActionNode round-trips through build_log/from_log" do
      node = ActionNode.new(AddOne, %{}, name: :add)
      workflow = Workflow.new(:single_action) |> Workflow.add(node)

      log = Workflow.build_log(workflow)
      restored = Workflow.from_log(log)

      original_component = Workflow.get_component(workflow, :add)
      restored_component = Workflow.get_component(restored, :add)

      assert restored_component.name == original_component.name
      assert restored_component.hash == original_component.hash

      original_results =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      restored_results =
        restored
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 6} in original_results
      assert %{value: 6} in restored_results
    end

    test "chained ActionNodes round-trip correctly" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      double = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:chain)
        |> Workflow.add(add)
        |> Workflow.add(double, to: :add)

      log = Workflow.build_log(workflow)
      restored = Workflow.from_log(log)

      original_results =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      restored_results =
        restored
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 6} in original_results
      assert %{value: 12} in original_results
      assert original_results == restored_results
    end
  end

  describe "SignalMatch round-trip" do
    test "SignalMatch round-trips through build_log/from_log" do
      gate = SignalMatch.new("order.paid", name: :gate)
      workflow = Workflow.new(:signal_test) |> Workflow.add(gate)

      log = Workflow.build_log(workflow)
      restored = Workflow.from_log(log)

      original_component = Workflow.get_component(workflow, :gate)
      restored_component = Workflow.get_component(restored, :gate)

      assert restored_component.pattern == original_component.pattern
      assert restored_component.hash == original_component.hash
    end
  end

  describe "mixed workflow round-trip" do
    test "mixed ActionNode + SignalMatch workflow round-trips" do
      gate = SignalMatch.new("order.paid", name: :gate)
      action = ActionNode.new(AddOne, %{}, name: :process)

      workflow =
        Workflow.new(:mixed)
        |> Workflow.add(gate)
        |> Workflow.add(action, to: :gate)

      log = Workflow.build_log(workflow)
      restored = Workflow.from_log(log)

      input = %{type: "order.paid", value: 5}

      original_results =
        workflow
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      restored_results =
        restored
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions()

      assert Enum.any?(original_results, &match?(%{value: 6}, &1))
      assert original_results == restored_results
    end
  end

  describe "binary serialization round-trip" do
    test "binary serialization round-trip" do
      add = ActionNode.new(AddOne, %{}, name: :add)
      double = ActionNode.new(Double, %{}, name: :double)

      workflow =
        Workflow.new(:binary_test)
        |> Workflow.add(add)
        |> Workflow.add(double, to: :add)

      log = Workflow.build_log(workflow)
      binary = :erlang.term_to_binary(log)
      restored_log = :erlang.binary_to_term(binary)
      restored = Workflow.from_log(restored_log)

      original_results =
        workflow
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      restored_results =
        restored
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 6} in original_results
      assert %{value: 12} in original_results
      assert original_results == restored_results
    end
  end
end
