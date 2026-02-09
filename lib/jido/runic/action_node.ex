defmodule Jido.Runic.ActionNode do
  @moduledoc """
  A Runic workflow node that wraps a Jido Action module.

  ActionNode preserves the full identity and semantics of a Jido Action within
  a Runic workflow graph. Unlike wrapping an action as a bare `Runic.Workflow.Step`,
  ActionNode retains:

  - **Stable identity**: Content-addressed hash based on `{action_mod, params}` — not
    an anonymous function reference — so hashes are stable across recompiles.
  - **Schema introspection**: Input/output schemas derived from the action module's
    NimbleOptions schema, exposed via the `Runic.Component` protocol.
  - **Full Jido execution semantics**: Execution delegates to `Jido.Exec.run/4`, which
    provides parameter validation, lifecycle hooks, output validation, retries,
    compensation, and telemetry.

  ## Usage

      alias Jido.Runic.ActionNode

      node = ActionNode.new(MyApp.Actions.ValidateOrder, %{strict: true}, name: :validate)

      workflow =
        Runic.Workflow.new(name: :pipeline)
        |> Runic.Workflow.add(node)

      workflow
      |> Runic.Workflow.react_until_satisfied(%{order_id: "123"})
      |> Runic.Workflow.raw_productions()

  ## Execution

  During Runic's three-phase execution cycle:

  1. **Prepare** — Extracts the input fact and builds a `%Runnable{}` with causal context.
  2. **Execute** — Merges the fact's value into the node's params and calls
     `Jido.Exec.run/4`. Timeout defaults to `0` (inline execution) so that
     Runic's scheduler owns concurrency and timeout control.
  3. **Apply** — The `apply_fn` on the completed Runnable reduces the result fact
     back into the workflow graph.
  """

  alias Runic.Workflow.Components

  defstruct [:name, :hash, :action_mod, :params, :context, :exec_opts, :inputs, :outputs, executor: :local]

  @type t :: %__MODULE__{
          name: atom(),
          hash: integer(),
          action_mod: module(),
          params: map(),
          context: map(),
          exec_opts: keyword(),
          inputs: keyword(),
          outputs: keyword(),
          executor: :local | {:child, atom()} | {:child, atom(), term()}
        }

  @doc """
  Creates a new ActionNode wrapping the given Jido Action module.

  ## Options

  - `:name` — Node name used for graph lookups. Defaults to the action module's
    last segment, underscored (e.g., `MyApp.Actions.ValidateOrder` → `:validate_order`).
  - `:context` — Jido execution context map passed to `Jido.Exec.run/4`. Default `%{}`.
  - `:timeout` — Override the Exec timeout. Default `0` (inline, no spawned task).
  - Any other options are forwarded to `Jido.Exec.run/4` as exec opts.
  """
  @spec new(module(), map(), keyword()) :: t()
  def new(action_mod, params \\ %{}, opts \\ []) do
    Code.ensure_loaded(action_mod)

    {name, opts} = Keyword.pop_lazy(opts, :name, fn -> derive_name(action_mod) end)
    {context, opts} = Keyword.pop(opts, :context, %{})
    {executor, opts} = Keyword.pop(opts, :executor, :local)
    exec_opts = Keyword.put_new(opts, :timeout, 0)

    %__MODULE__{
      name: name,
      hash: Components.fact_hash({:jido_action_node, action_mod, params, name}),
      action_mod: action_mod,
      params: params,
      context: context,
      exec_opts: exec_opts,
      executor: executor,
      inputs: derive_inputs(action_mod),
      outputs: derive_outputs(action_mod)
    }
  end

  @doc """
  Returns the action module's metadata map if available.
  """
  @spec action_metadata(t()) :: map() | nil
  def action_metadata(%__MODULE__{action_mod: mod}) do
    if function_exported?(mod, :to_json, 0), do: mod.to_json(), else: nil
  end

  defp derive_name(action_mod) do
    action_mod
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp derive_inputs(action_mod) do
    if function_exported?(action_mod, :schema, 0) do
      case action_mod.schema() do
        schema when is_list(schema) and schema != [] ->
          Enum.map(schema, fn {key, key_opts} ->
            {key, [type: Keyword.get(key_opts, :type, :any), doc: Keyword.get(key_opts, :doc, "")]}
          end)

        _ ->
          default_inputs()
      end
    else
      default_inputs()
    end
  end

  defp derive_outputs(action_mod) do
    if function_exported?(action_mod, :output_schema, 0) do
      case action_mod.output_schema() do
        schema when is_list(schema) and schema != [] ->
          Enum.map(schema, fn {key, key_opts} ->
            {key, [type: Keyword.get(key_opts, :type, :any), doc: Keyword.get(key_opts, :doc, "")]}
          end)

        _ ->
          default_outputs()
      end
    else
      default_outputs()
    end
  end

  defp default_inputs, do: [input: [type: :any, doc: "Input to the action"]]
  defp default_outputs, do: [result: [type: :any, doc: "Action result"]]
end

defimpl Runic.Workflow.Invokable, for: Jido.Runic.ActionNode do
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, CausalContext, HookRunner}

  @doc """
  ActionNode is an execute node — it produces facts (not a gate/predicate).
  """
  def match_or_execute(_node), do: :execute

  @doc """
  High-level invoke that delegates to the 3-phase cycle.
  """
  def invoke(%Jido.Runic.ActionNode{} = node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    executed = execute(node, runnable)
    Workflow.apply_runnable(workflow, executed)
  end

  @doc """
  Phase 1: Extract minimal context from workflow into a Runnable.
  """
  def prepare(%Jido.Runic.ActionNode{} = node, workflow, fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, node.hash)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  @doc """
  Phase 2: Execute the Jido Action via Jido.Exec.run/4.
  No workflow access — safe for parallel dispatch.
  """
  def execute(%Jido.Runic.ActionNode{} = node, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, node, fact) do
      merged_params = Map.merge(node.params, to_params(fact.value))

      case Jido.Exec.run(node.action_mod, merged_params, node.context, node.exec_opts) do
        {:ok, result} ->
          result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

          case HookRunner.run_after(ctx, node, fact, result_fact) do
            {:ok, after_apply_fns} ->
              apply_fn = fn workflow ->
                workflow
                |> Workflow.apply_hook_fns(before_apply_fns)
                |> Workflow.log_fact(result_fact)
                |> Workflow.draw_connection(node, result_fact, :produced)
                |> Workflow.apply_hook_fns(after_apply_fns)
                |> Workflow.prepare_next_runnables(node, result_fact)
                |> Workflow.mark_runnable_as_ran(node, fact)
              end

              Runnable.complete(runnable, result_fact, apply_fn)

            {:error, reason} ->
              Runnable.fail(runnable, {:hook_error, reason})
          end

        {:ok, result, extra} ->
          result_fact =
            Fact.new(value: %{result: result, extra: extra}, ancestry: {node.hash, fact.hash})

          case HookRunner.run_after(ctx, node, fact, result_fact) do
            {:ok, after_apply_fns} ->
              apply_fn = fn workflow ->
                workflow
                |> Workflow.apply_hook_fns(before_apply_fns)
                |> Workflow.log_fact(result_fact)
                |> Workflow.draw_connection(node, result_fact, :produced)
                |> Workflow.apply_hook_fns(after_apply_fns)
                |> Workflow.prepare_next_runnables(node, result_fact)
                |> Workflow.mark_runnable_as_ran(node, fact)
              end

              Runnable.complete(runnable, result_fact, apply_fn)

            {:error, reason} ->
              Runnable.fail(runnable, {:hook_error, reason})
          end

        {:error, reason} ->
          Runnable.fail(runnable, reason)
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp to_params(value) when is_map(value), do: value
  defp to_params(value), do: %{input: value}
end

defimpl Runic.Component, for: Jido.Runic.ActionNode do
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
      Jido.Runic.ActionNode.new(
        unquote(node.action_mod),
        unquote(Macro.escape(node.params)),
        name: unquote(node.name)
      )
    end
  end

  def hash(node), do: node.hash

  def inputs(%Jido.Runic.ActionNode{inputs: inputs}), do: inputs
  def outputs(%Jido.Runic.ActionNode{outputs: outputs}), do: outputs
end

defimpl Runic.Transmutable, for: Jido.Runic.ActionNode do
  alias Runic.Workflow

  def transmute(node), do: to_workflow(node)

  def to_workflow(%Jido.Runic.ActionNode{} = node) do
    Workflow.new(name: node.name)
    |> Workflow.add(node)
  end

  def to_component(node), do: node
end
