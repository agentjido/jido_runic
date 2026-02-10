defmodule Jido.Runic.SignalFact do
  @moduledoc """
  Bidirectional adapter between Jido Signals and Runic Facts.

  Maps Jido's causality tracking (signal.source, signal.jidocause) to
  Runic's fact ancestry chain, ensuring provenance is continuous across
  both systems.
  """

  alias Runic.Workflow.Fact

  @doc """
  Convert a Jido Signal (or plain map) into a Runic Fact.

  Options:
  * `:ancestry_mode` — `:hash` (default) to hash source/jidocause or `:raw` to preserve them.
  """
  @spec from_signal(Jido.Signal.t(), keyword()) :: Fact.t()
  def from_signal(signal, opts \\ [])

  def from_signal(%{data: data} = signal, opts) do
    ancestry = build_ancestry(signal, opts)
    Fact.new(value: data, ancestry: ancestry)
  end

  def from_signal(signal, opts) when is_map(signal) do
    data = Map.get(signal, :data, signal)
    ancestry = build_ancestry(signal, opts)
    Fact.new(value: data, ancestry: ancestry)
  end

  @doc """
  Convert a Runic Fact back into a Jido Signal.

  Options:
  * `:type` — signal type (default: `"runic.production"`).
  * `:source` — signal source path (default: `\"/runic/workflow\"`).
  * `:include_ancestry?` — when true and ancestry present, rehydrate `source`/`jidocause` from it.
  """
  @spec to_signal(Fact.t(), keyword()) :: Jido.Signal.t()
  def to_signal(%Fact{} = fact, opts \\ []) do
    type = Keyword.get(opts, :type, "runic.production")
    default_source = Keyword.get(opts, :source, "/runic/workflow")
    include_ancestry? = Keyword.get(opts, :include_ancestry?, false)

    {source, jidocause} =
      case {include_ancestry?, fact.ancestry} do
        {true, {src, cause}} -> {src || default_source, cause}
        _ -> {default_source, nil}
      end

    Jido.Signal.new!(type, fact.value, source: source, jidocause: jidocause)
  end

  defp build_ancestry(signal, opts) do
    mode = Keyword.get(opts, :ancestry_mode, :hash)
    source = Map.get(signal, :source)
    cause = Map.get(signal, :jidocause)

    cond do
      source && cause ->
        case mode do
          :raw -> {source, cause}
          _ -> {:erlang.phash2(source), :erlang.phash2(cause)}
        end

      source ->
        case mode do
          :raw -> {source, nil}
          _ -> {:erlang.phash2(source), nil}
        end

      true ->
        nil
    end
  end
end
