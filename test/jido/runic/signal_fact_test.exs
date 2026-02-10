defmodule Jido.RunicTest.SignalFact do
  use ExUnit.Case, async: true

  alias Jido.Runic.SignalFact
  alias Runic.Workflow.Fact

  describe "from_signal/1" do
    test "converts a signal with :data key into a fact" do
      signal = Jido.Signal.new!("test.event", %{foo: "bar"}, source: "/test")
      fact = SignalFact.from_signal(signal)

      assert %Fact{} = fact
      assert fact.value == %{foo: "bar"}
      assert is_integer(fact.hash)
    end

    test "uses full map as data when :data key is absent" do
      map = %{some_key: "some_value"}
      fact = SignalFact.from_signal(map)

      assert %Fact{} = fact
      assert fact.value == map
      assert fact.ancestry == nil
    end

    test "builds ancestry from source and cause (hash mode default)" do
      signal = %{data: %{x: 1}, source: "/origin", jidocause: "cause-abc"}
      fact = SignalFact.from_signal(signal)

      assert fact.ancestry == {:erlang.phash2("/origin"), :erlang.phash2("cause-abc")}
    end

    test "builds ancestry raw when ancestry_mode: :raw" do
      signal = %{data: %{x: 1}, source: "/origin", jidocause: "cause-abc"}
      fact = SignalFact.from_signal(signal, ancestry_mode: :raw)

      assert fact.ancestry == {"/origin", "cause-abc"}
    end

    test "builds ancestry with source only" do
      signal = %{data: %{x: 1}, source: "/origin"}
      fact = SignalFact.from_signal(signal)

      assert fact.ancestry == {:erlang.phash2("/origin"), nil}
    end

    test "sets ancestry to nil when neither source nor cause is present" do
      signal = %{data: %{x: 1}}
      fact = SignalFact.from_signal(signal)

      assert fact.ancestry == nil
    end
  end

  describe "to_signal/2" do
    test "converts a fact to a signal with default opts" do
      fact = Fact.new(value: %{result: 42})
      signal = SignalFact.to_signal(fact)

      assert signal.type == "runic.production"
      assert signal.source == "/runic/workflow"
      assert signal.data == %{result: 42}
    end

    test "converts a fact to a signal with custom type and source" do
      fact = Fact.new(value: %{result: 99})
      signal = SignalFact.to_signal(fact, type: "custom.type", source: "/custom/source")

      assert signal.type == "custom.type"
      assert signal.source == "/custom/source"
      assert signal.data == %{result: 99}
    end

    test "includes ancestry in signal when include_ancestry?: true" do
      fact = %Fact{value: %{result: 7}, ancestry: {"/origin", "cause-1"}}
      signal = SignalFact.to_signal(fact, include_ancestry?: true)

      assert signal.source == "/origin"
      assert Map.get(signal.extensions, "jidocause") == "cause-1"
    end
  end
end
