defmodule JidoRunic.Introspection do
  @moduledoc """
  Provenance queries and workflow execution summaries.

  Provides utilities to trace how facts were produced through a workflow
  and to generate summary statistics about a workflow's execution state.
  """

  alias Runic.Workflow
  alias Runic.Workflow.Fact

  @type fact_source :: %Workflow{} | %{facts: [Fact.t()]}
  @type provenance_entry :: {Fact.t(), integer() | nil}

  @doc """
  Walk Fact ancestry back through the workflow's facts.

  Returns a list of `{fact, producing_node_hash_or_nil}` tuples ordered
  from the root input fact to the target fact identified by `fact_hash`.

  Accepts either a `%Runic.Workflow{}` or a map with a `:facts` key
  (e.g. a Studio pipeline result).

  Returns `{:ok, chain}` on success, or `{:error, reason}` if the target
  fact is not found.
  """
  @spec provenance_chain(fact_source(), Fact.hash()) ::
          {:ok, [provenance_entry()]} | {:error, term()}
  def provenance_chain(source, fact_hash) do
    facts = extract_facts(source)
    index = Map.new(facts, fn fact -> {fact.hash, fact} end)

    case Map.get(index, fact_hash) do
      nil -> {:error, :fact_not_found}
      target -> {:ok, build_chain(target, index, [])}
    end
  end

  defp build_chain(%Fact{ancestry: nil} = fact, _index, acc) do
    [{fact, nil} | acc]
  end

  defp build_chain(%Fact{ancestry: {producer_hash, parent_hash}} = fact, index, acc) do
    acc = [{fact, producer_hash} | acc]

    case Map.get(index, parent_hash) do
      nil -> acc
      parent -> build_chain(parent, index, acc)
    end
  end

  @doc """
  Return a summary map with execution statistics for the given workflow.

  Keys returned:

    * `:total_nodes` — count of registered components
    * `:facts_produced` — count of facts in the workflow
    * `:satisfied` — `true` when the workflow has no remaining runnables
    * `:productions` — count of raw production values
  """
  @spec execution_summary(Workflow.t()) :: %{
          total_nodes: non_neg_integer(),
          facts_produced: non_neg_integer(),
          satisfied: boolean(),
          productions: non_neg_integer()
        }
  def execution_summary(%Workflow{} = workflow) do
    %{
      total_nodes: workflow |> Workflow.components() |> map_size(),
      facts_produced: workflow |> Workflow.facts() |> length(),
      satisfied: not Workflow.is_runnable?(workflow),
      productions: workflow |> Workflow.raw_productions() |> length()
    }
  end

  defp extract_facts(%Workflow{} = workflow), do: Workflow.facts(workflow)
  defp extract_facts(%{facts: facts}) when is_list(facts), do: facts
end
