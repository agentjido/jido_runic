defmodule JidoRunicTest.SignalFactTest do
  use ExUnit.Case, async: true

  alias JidoRunic.SignalFact
  alias Runic.Workflow.Fact

  describe "from_signal/1" do
    test "converts a signal map to a fact" do
      signal = %{
        data: %{value: 42},
        source: "/test/agent",
        type: "test.event"
      }

      fact = SignalFact.from_signal(signal)
      assert fact.value == %{value: 42}
      assert fact.ancestry != nil
      assert is_integer(fact.hash)
    end

    test "handles signal without cause" do
      signal = %{
        data: %{value: 1},
        source: "/test"
      }

      fact = SignalFact.from_signal(signal)
      assert fact.value == %{value: 1}
      {producer, parent} = fact.ancestry
      assert is_integer(producer)
      assert parent == nil
    end

    test "handles signal with cause" do
      signal = %{
        data: %{value: 1},
        source: "/test",
        jidocause: "cause-signal-id"
      }

      fact = SignalFact.from_signal(signal)
      {producer, parent} = fact.ancestry
      assert is_integer(producer)
      assert is_integer(parent)
    end

    test "handles signal without source" do
      signal = %{data: %{value: 1}}
      fact = SignalFact.from_signal(signal)
      assert fact.value == %{value: 1}
      assert fact.ancestry == nil
    end
  end

  describe "to_signal/2" do
    test "converts a fact to a signal" do
      fact = Fact.new(value: %{result: "hello"}, ancestry: nil)
      signal = SignalFact.to_signal(fact)

      assert signal.type == "runic.production"
      assert signal.data == %{result: "hello"}
    end

    test "accepts custom type and source" do
      fact = Fact.new(value: %{done: true}, ancestry: nil)
      signal = SignalFact.to_signal(fact, type: "studio.complete", source: "/studio")

      assert signal.type == "studio.complete"
      assert signal.source == "/studio"
    end
  end

  describe "round-trip" do
    test "signal → fact → signal preserves data" do
      original_signal = %{
        data: %{value: 42, nested: %{key: "value"}},
        source: "/test/agent",
        type: "test.event"
      }

      fact = SignalFact.from_signal(original_signal)
      round_tripped = SignalFact.to_signal(fact, type: "test.event", source: "/test/agent")

      assert round_tripped.data == original_signal.data
      assert round_tripped.type == original_signal.type
      assert round_tripped.source == original_signal.source
    end
  end
end
