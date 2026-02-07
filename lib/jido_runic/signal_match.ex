defmodule JidoRunic.SignalMatch do
  @moduledoc """
  A Runic match node that gates downstream execution based on
  Jido signal type patterns. Uses prefix matching compatible
  with Jido's routing patterns.
  """

  defstruct [:name, :hash, :pattern]

  @type t :: %__MODULE__{
          name: atom(),
          hash: integer(),
          pattern: String.t()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(pattern, opts \\ []) do
    name = opts[:name] || :"signal_match_#{pattern}"

    %__MODULE__{
      name: name,
      hash: Runic.Workflow.Components.fact_hash({:signal_match, pattern, name}),
      pattern: pattern
    }
  end
end

defimpl Runic.Workflow.Invokable, for: JidoRunic.SignalMatch do
  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, CausalContext}

  def match_or_execute(_node), do: :match

  def invoke(%JidoRunic.SignalMatch{pattern: pattern} = node, workflow, fact) do
    if matches_pattern?(fact.value, pattern) do
      workflow
      |> Workflow.prepare_next_runnables(node, fact)
      |> Workflow.mark_runnable_as_ran(node, fact)
    else
      workflow
      |> Workflow.mark_runnable_as_ran(node, fact)
    end
  end

  def prepare(%JidoRunic.SignalMatch{} = node, workflow, fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(%JidoRunic.SignalMatch{pattern: pattern} = node, %Runnable{input_fact: fact} = runnable) do
    matched = matches_pattern?(fact.value, pattern)

    apply_fn = fn workflow ->
      if matched do
        workflow
        |> Workflow.prepare_next_runnables(node, fact)
        |> Workflow.mark_runnable_as_ran(node, fact)
      else
        workflow
        |> Workflow.mark_runnable_as_ran(node, fact)
      end
    end

    if matched do
      Runnable.complete(runnable, fact, apply_fn)
    else
      Runnable.skip(runnable, apply_fn)
    end
  end

  defp matches_pattern?(%{type: type}, pattern) when is_binary(type) and is_binary(pattern) do
    String.starts_with?(type, pattern)
  end

  defp matches_pattern?(_, _), do: false
end

defimpl Runic.Component, for: JidoRunic.SignalMatch do
  alias Runic.Workflow

  def connectable?(_node, _other), do: true

  def connect(node, to, workflow) when is_list(to) do
    join =
      to
      |> Enum.map(fn
        %{hash: hash} -> hash
        other -> other
      end)
      |> Runic.Workflow.Join.new()

    wrk =
      Enum.reduce(to, workflow, fn
        %{hash: _} = parent, wrk -> Workflow.add_step(wrk, parent, join)
        _, wrk -> wrk
      end)

    wrk
    |> Workflow.add_step(join, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :signal_match})
    |> Workflow.register_component(node)
  end

  def connect(node, to, workflow) do
    workflow
    |> Workflow.add_step(to, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :signal_match})
    |> Workflow.register_component(node)
  end

  def source(node) do
    quote do
      JidoRunic.SignalMatch.new(unquote(node.pattern), name: unquote(node.name))
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [signal: [type: :any, doc: "Signal with type field"]]
  def outputs(_node), do: [signal: [type: :any, doc: "Matched signal passed through"]]
end

defimpl Runic.Transmutable, for: JidoRunic.SignalMatch do
  alias Runic.Workflow

  def transmute(node), do: to_workflow(node)

  def to_workflow(%JidoRunic.SignalMatch{} = node) do
    Workflow.new(name: node.name)
    |> Workflow.add(node)
  end

  def to_component(node), do: node
end
