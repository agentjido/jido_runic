defmodule Jido.RunicTest.Nodes.RaisingNode do
  defstruct [:name, :hash]
end

defimpl Runic.Workflow.Invokable, for: Jido.RunicTest.Nodes.RaisingNode do
  alias Runic.Workflow.{Runnable, CausalContext}

  def match_or_execute(_), do: :execute
  def invoke(_, _, _), do: raise("boom from invoke")

  def prepare(node, _workflow, fact) do
    ctx = CausalContext.new(node_hash: node.hash, input_fact: fact)
    {:ok, Runnable.new(node, fact, ctx)}
  end

  def execute(_, _), do: raise("unexpected crash")
end

defmodule Jido.RunicTest.Nodes.ThrowingNode do
  defstruct [:name, :hash]
end

defimpl Runic.Workflow.Invokable, for: Jido.RunicTest.Nodes.ThrowingNode do
  alias Runic.Workflow.{Runnable, CausalContext}

  def match_or_execute(_), do: :execute
  def invoke(_, _, _), do: throw(:unexpected_throw)

  def prepare(node, _workflow, fact) do
    ctx = CausalContext.new(node_hash: node.hash, input_fact: fact)
    {:ok, Runnable.new(node, fact, ctx)}
  end

  def execute(_, _), do: throw(:unexpected_throw)
end
