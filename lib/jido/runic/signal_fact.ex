defmodule Jido.Runic.SignalFact do
  @moduledoc """
  Bidirectional adapter between Jido Signals and Runic Facts.

  Maps Jido's causality tracking (signal.source, signal.jidocause) to
  Runic's fact ancestry chain, ensuring provenance is continuous across
  both systems.
  """

  alias Runic.Workflow.Fact

  @spec from_signal(Jido.Signal.t()) :: Fact.t()
  def from_signal(%{data: data} = signal) do
    ancestry = build_ancestry(signal)
    Fact.new(value: data, ancestry: ancestry)
  end

  def from_signal(signal) when is_map(signal) do
    data = Map.get(signal, :data, signal)
    ancestry = build_ancestry(signal)
    Fact.new(value: data, ancestry: ancestry)
  end

  @spec to_signal(Fact.t(), keyword()) :: Jido.Signal.t()
  def to_signal(%Fact{} = fact, opts \\ []) do
    type = Keyword.get(opts, :type, "runic.production")
    source = Keyword.get(opts, :source, "/runic/workflow")

    Jido.Signal.new!(type, fact.value, source: source)
  end

  defp build_ancestry(signal) do
    source = Map.get(signal, :source)
    cause = Map.get(signal, :jidocause)

    cond do
      source && cause ->
        {:erlang.phash2(source), :erlang.phash2(cause)}

      source ->
        {:erlang.phash2(source), nil}

      true ->
        nil
    end
  end
end
