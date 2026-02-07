defmodule JidoRunic.ActionNode do
  @moduledoc """
  A Runic workflow node wrapping a Jido Action module.

  Preserves action identity (module + params) for stable hashing,
  serialization, and introspection. Execution delegates to Jido's
  action runner rather than calling an anonymous function.
  """

  defstruct [:name, :hash, :action_mod, :params, :opts, :inputs, :outputs]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          hash: integer(),
          action_mod: module(),
          params: map(),
          opts: keyword(),
          inputs: keyword(),
          outputs: keyword()
        }

  @spec new(module(), map(), keyword()) :: t()
  def new(action_mod, params \\ %{}, opts \\ []) do
    name =
      opts[:name] ||
        action_mod |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

    hash =
      Runic.Workflow.Components.fact_hash({:action_node, action_mod, params, opts[:name]})

    %__MODULE__{
      name: name,
      hash: hash,
      action_mod: action_mod,
      params: params,
      opts: Keyword.drop(opts, [:name]),
      inputs: derive_inputs(action_mod),
      outputs: [result: [type: :any, doc: "Action result"]]
    }
  end

  defp derive_inputs(action_mod) do
    Code.ensure_loaded(action_mod)

    if function_exported?(action_mod, :schema, 0) do
      case action_mod.schema() do
        schema when is_list(schema) and schema != [] ->
          Enum.map(schema, fn {key, key_opts} ->
            {key,
             [type: Keyword.get(key_opts, :type, :any), doc: Keyword.get(key_opts, :doc, "")]}
          end)

        _ ->
          [input: [type: :any, doc: "Input to the action"]]
      end
    else
      [input: [type: :any, doc: "Input to the action"]]
    end
  end
end

defimpl Runic.Workflow.Invokable, for: JidoRunic.ActionNode do
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, CausalContext}

  def match_or_execute(_node), do: :execute

  def invoke(%JidoRunic.ActionNode{} = node, workflow, fact) do
    merged_params = Map.merge(node.params, to_params(fact.value))

    case Jido.Exec.run(node.action_mod, merged_params) do
      {:ok, result} ->
        result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

        workflow
        |> Workflow.log_fact(result_fact)
        |> Workflow.draw_connection(node, result_fact, :produced)
        |> Workflow.mark_runnable_as_ran(node, fact)
        |> Workflow.prepare_next_runnables(node, result_fact)

      {:error, _reason} ->
        workflow
        |> Workflow.mark_runnable_as_ran(node, fact)
    end
  end

  def prepare(%JidoRunic.ActionNode{} = node, workflow, fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(%JidoRunic.ActionNode{} = node, %Runnable{input_fact: fact} = runnable) do
    merged_params = Map.merge(node.params, to_params(fact.value))

    case Jido.Exec.run(node.action_mod, merged_params) do
      {:ok, result} ->
        result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

        apply_fn = fn workflow ->
          workflow
          |> Workflow.log_fact(result_fact)
          |> Workflow.draw_connection(node, result_fact, :produced)
          |> Workflow.mark_runnable_as_ran(node, fact)
          |> Workflow.prepare_next_runnables(node, result_fact)
        end

        Runnable.complete(runnable, result_fact, apply_fn)

      {:error, reason} ->
        Runnable.fail(runnable, reason)
    end
  end

  defp to_params(value) when is_map(value), do: value
  defp to_params(value), do: %{input: value}
end

defimpl Runic.Component, for: JidoRunic.ActionNode do
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
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :action_node})
    |> Workflow.register_component(node)
  end

  def connect(node, to, workflow) do
    workflow
    |> Workflow.add_step(to, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :action_node})
    |> Workflow.register_component(node)
  end

  def source(node) do
    quote do
      JidoRunic.ActionNode.new(
        unquote(node.action_mod),
        unquote(Macro.escape(node.params)),
        name: unquote(node.name)
      )
    end
  end

  def hash(node), do: node.hash

  def inputs(%JidoRunic.ActionNode{inputs: inputs}), do: inputs
  def outputs(%JidoRunic.ActionNode{outputs: outputs}), do: outputs
end

defimpl Runic.Transmutable, for: JidoRunic.ActionNode do
  alias Runic.Workflow

  def transmute(node), do: to_workflow(node)

  def to_workflow(%JidoRunic.ActionNode{} = node) do
    Workflow.new(name: node.name)
    |> Workflow.add(node)
  end

  def to_component(node), do: node
end
