# Jido + Runic Integration Report

## Executive Summary

Runic and Jido are architecturally complementary. Runic excels at **what** to do — explicit dependency graphs, joins, fan-out/fan-in, provenance, and persistence. Jido excels at **how** to do it — signal routing, effect execution via directives, action lifecycle (retries, compensation), and runtime topology.

The natural seam between them is Runic's `%Runnable{}` abstraction mapped to Jido's directive-based execution model. This report details five concrete integration points, protocol mappings, a recommended build order, and code sketches.

---

## Architecture Alignment

### Jido Core Loop

```
Signal → AgentServer → Agent.cmd/2 → {agent, directives} → DirectiveExec
```

- **Agent**: Immutable struct. `cmd/2` is a pure function that returns `{updated_agent, directives}`.
- **Action** (`jido_action`): Schema-validated unit of work. `run(params, context) → {:ok, result}`. Has lifecycle hooks, retries, compensation. Convertible to LLM tool definitions via `to_tool()`.
- **Signal** (`jido_signal`): CloudEvents-based message envelope. Routed via trie-based pattern matching. Dispatched via adapters (PID, PubSub, HTTP). Has causality tracking (cause/effect chains, conversation grouping).
- **Directive**: Effect description emitted by `cmd/2` — `Emit`, `Spawn`, `SpawnAgent`, `Schedule`, `Stop`. Interpreted by AgentServer runtime. Never modifies agent state.
- **Strategy**: Execution pattern (Direct, FSM, custom) that controls how actions are processed within `cmd/2`.

### Runic Core Loop

```
Input → Workflow.plan_eagerly/2 → Workflow.react_until_satisfied/1 → Facts (productions)
```

- **Workflow**: DAG of components (Steps, Rules, StateMachines, Accumulators, Map/Reduce, Joins). Graph-based, lazily evaluated.
- **Fact**: Value wrapper with `ancestry: {producer_hash, parent_fact_hash}` for provenance tracking.
- **Runnable**: Self-contained unit of work extracted from the workflow. Contains node, input fact, and causal context — no workflow reference.
- **3-Phase Execution**: Prepare (extract `%Runnable{}` from workflow) → Execute (run in isolation, parallelizable) → Apply (reduce results back via `apply_fn`).
- **Protocols**: `Invokable` (runtime execution), `Component` (graph composition, type compatibility), `Transmutable` (data → workflow/component conversion).

### Where They Meet

| Jido Concept | Runic Concept | Mapping |
|---|---|---|
| Signal | Fact | Incoming signal becomes input fact with ancestry derived from signal causality |
| Action | ActionNode (custom Invokable) | Jido action module wrapped as a Runic graph node |
| Directive | Leaf production | Workflow outputs converted to directives at the boundary |
| Strategy | Workflow (as execution engine) | Runic workflow replaces Direct/FSM as a strategy |
| AgentServer | External scheduler | Directive executor runs Phase 2 (execute) outside `cmd/2` |
| `cmd/2` purity | Prepare + Apply phases | Only pure planning and result application happen inside `cmd/2` |

---

## Integration Point 1: Jido Actions as Runic Nodes

### Problem

Jido Actions have rich semantics — schema validation, lifecycle hooks (`on_before_validate_params`, `on_after_run`), retries, compensation, AI tool conversion. Wrapping an action as a bare `Runic.Workflow.Step` with `work: fn input -> Action.run(input, ctx) end` discards all of this.

### Solution: `JidoRunic.ActionNode`

A custom Runic node type that preserves Jido action identity and metadata, with protocol implementations for `Invokable`, `Component`, and `Transmutable`.

```elixir
defmodule JidoRunic.ActionNode do
  @moduledoc """
  A Runic workflow node wrapping a Jido Action module.

  Preserves action identity (module + params) for stable hashing,
  serialization, and introspection. Execution delegates to Jido's
  action runner (Jido.Exec) rather than calling an anonymous function.
  """

  defstruct [:name, :hash, :action_mod, :params, :opts, :inputs, :outputs]

  def new(action_mod, params \\ %{}, opts \\ []) do
    name = opts[:name] || action_mod |> Module.split() |> List.last() |> Macro.underscore()
    hash = :erlang.phash2({action_mod, params, opts})

    %__MODULE__{
      name: name,
      hash: hash,
      action_mod: action_mod,
      params: params,
      opts: opts,
      inputs: derive_inputs(action_mod),
      outputs: derive_outputs(action_mod)
    }
  end

  # Derive Runic-compatible input schema from Jido action's NimbleOptions schema
  defp derive_inputs(action_mod) do
    if function_exported?(action_mod, :schema, 0) do
      action_mod.schema()
      |> Enum.map(fn {key, opts} ->
        {key, [type: Keyword.get(opts, :type, :any), doc: Keyword.get(opts, :doc, "")]}
      end)
    else
      [action: [type: :any, doc: "Input to the action"]]
    end
  end

  defp derive_outputs(_action_mod) do
    [result: [type: :any, doc: "Action result"]]
  end
end
```

### Protocol Implementations

#### Transmutable — Convert `{ActionMod, params}` tuples to ActionNodes

```elixir
defimpl Runic.Transmutable, for: JidoRunic.ActionNode do
  def transmute(node), do: to_workflow(node)

  def to_workflow(%JidoRunic.ActionNode{} = node) do
    Runic.Workflow.new(name: node.name)
    |> Runic.Workflow.add(node)
  end

  def to_component(node), do: node
end
```

#### Invokable — Three-phase execution

```elixir
defimpl Runic.Workflow.Invokable, for: JidoRunic.ActionNode do
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, CausalContext}

  def match_or_execute(_node), do: :execute

  def invoke(%JidoRunic.ActionNode{} = node, workflow, fact) do
    merged_params = Map.merge(node.params, to_params(fact.value))
    {:ok, result} = Jido.Exec.run(node.action_mod, merged_params)
    result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(node, result_fact, :produced)
    |> Workflow.mark_runnable_as_ran(node, fact)
    |> Workflow.prepare_next_runnables(node, result_fact)
  end

  def prepare(%JidoRunic.ActionNode{} = node, workflow, fact) do
    context = CausalContext.new(
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
```

#### Component — Schema introspection and connection

```elixir
defimpl Runic.Component, for: JidoRunic.ActionNode do
  alias Runic.Workflow

  def components(node), do: [{node.name, node}]
  def connectables(node, _other), do: components(node)
  def connectable?(_node, _other), do: true

  def connect(node, to, workflow) do
    workflow
    |> Workflow.add_step(to, node)
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
  def inputs(node), do: node.inputs
  def outputs(node), do: node.outputs
end
```

### Usage

```elixir
require Runic
alias JidoRunic.ActionNode

# Wrap Jido actions as Runic nodes
validate = ActionNode.new(MyApp.Actions.ValidateOrder, %{}, name: :validate)
enrich   = ActionNode.new(MyApp.Actions.EnrichCustomer, %{}, name: :enrich)
fulfill  = ActionNode.new(MyApp.Actions.FulfillOrder, %{}, name: :fulfill)

# Compose into a Runic workflow DAG
workflow = Runic.workflow(
  name: :order_pipeline,
  steps: [
    {validate, [enrich, fulfill]}
  ]
)
```

---

## Integration Point 2: Signals as Facts

### Problem

Jido Signals carry rich metadata (CloudEvents envelope, causality chain, conversation grouping). Runic Facts carry ancestry `{producer_hash, parent_fact_hash}`. These need to align so that provenance is continuous across both systems.

### Solution: Signal-to-Fact adapter

```elixir
defmodule JidoRunic.SignalFact do
  alias Runic.Workflow.Fact

  @doc """
  Convert a Jido Signal into a Runic Fact.

  The signal's `id` and `source` are hashed into the fact's ancestry,
  linking Runic's provenance chain back to Jido's causality tracking.
  """
  def from_signal(signal) do
    ancestry =
      if signal.jidocause do
        # Link to the causing signal's hash
        {:erlang.phash2(signal.source), :erlang.phash2(signal.jidocause)}
      else
        nil
      end

    Fact.new(value: signal.data, ancestry: ancestry)
  end

  @doc """
  Convert a Runic Fact (leaf production) back to a Jido Signal.
  """
  def to_signal(fact, opts \\ []) do
    Jido.Signal.new!(
      Keyword.get(opts, :type, "runic.production"),
      fact.value,
      source: Keyword.get(opts, :source, "/runic/workflow")
    )
  end
end
```

### Causality Mapping

| Jido Signal Field | Runic Fact Field | Mapping |
|---|---|---|
| `signal.id` | `fact.hash` | Content-addressed from `{value, ancestry}` |
| `signal.source` | `fact.ancestry` element 0 | Hashed into producer position |
| `signal.jidocause` | `fact.ancestry` element 1 | Hashed into parent fact position |
| `signal.data` | `fact.value` | Direct mapping |

This means a query like "why did this agent produce output X?" can be answered by tracing Runic's fact ancestry back through the DAG, then jumping to Jido's signal causality chain at the workflow boundary.

---

## Integration Point 3: `Jido.Strategy.Runic`

### Problem

Jido's existing strategies (Direct, FSM) handle single-action or state-machine execution. Neither supports DAG-based workflows with joins, fan-out/fan-in, or conditional branching across multiple concurrent actions.

### Solution: Runic workflow as a Jido execution strategy

The key insight: **`cmd/2` must stay pure**. Runic's 3-phase model maps perfectly to Jido's architecture:

- **Phase 1 (Prepare)**: Inside `cmd/2` — plan the workflow, extract runnables
- **Phase 2 (Execute)**: Outside `cmd/2` — AgentServer executes runnables via directives
- **Phase 3 (Apply)**: Inside `cmd/2` — apply completed runnable results back to workflow

```
┌──────────────────────────────────────────────────────────────────────┐
│                       Signal arrives                                │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  AgentServer                                                        │
│  ──────────                                                         │
│  Routes signal to Agent.cmd/2                                       │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Agent.cmd/2  (PURE — Phase 1 + Phase 3)                            │
│  ──────────────────────────────────                                  │
│  1. Convert signal → Runic Fact                                     │
│  2. Workflow.plan_eagerly(workflow, fact)                            │
│  3. Workflow.prepare_for_dispatch(workflow) → {wf, [runnables]}     │
│  4. Return {agent_with_updated_workflow, [ExecuteRunnable, ...]}     │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  DirectiveExec  (EFFECTFUL — Phase 2)                               │
│  ─────────────────────────────────                                   │
│  For each ExecuteRunnable directive:                                 │
│    Invokable.execute(runnable.node, runnable)                       │
│    → Send result back as "runic.runnable.completed" signal          │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Agent.cmd/2  (PURE — Phase 3)                                      │
│  ─────────────────────────────                                       │
│  1. Receive completion signal with executed runnable                 │
│  2. Workflow.apply_runnable(workflow, runnable)                      │
│  3. If Workflow.is_runnable?(workflow) → emit more directives       │
│  4. Else → extract leaf productions as final directives             │
└──────────────────────────────────────────────────────────────────────┘
```

### Sketch: ExecuteRunnable Directive

```elixir
defmodule JidoRunic.Directive.ExecuteRunnable do
  @moduledoc """
  A Jido directive that schedules execution of a Runic Runnable.

  The AgentServer interprets this directive by running the runnable
  (potentially in a Task, worker pool, or via Jido.Exec) and sending
  the result back to the agent as a completion signal.
  """

  defstruct [:runnable_id, :node, :runnable]
end
```

### Sketch: Strategy Module

```elixir
defmodule JidoRunic.Strategy do
  @moduledoc """
  A Jido execution strategy powered by a Runic workflow DAG.

  The agent's state includes a `workflow` field containing a
  `%Runic.Workflow{}`. Incoming signals are converted to facts
  and fed into the workflow. Runnables are emitted as directives
  for the AgentServer to execute.
  """

  def handle_signal(agent, signal) do
    workflow = agent.state.workflow

    # Phase 1: Plan
    fact = JidoRunic.SignalFact.from_signal(signal)
    workflow = Runic.Workflow.plan_eagerly(workflow, fact.value)
    {workflow, runnables} = Runic.Workflow.prepare_for_dispatch(workflow)

    # Produce directives for each runnable
    directives =
      Enum.map(runnables, fn runnable ->
        %JidoRunic.Directive.ExecuteRunnable{
          runnable_id: runnable.id,
          node: runnable.node,
          runnable: runnable
        }
      end)

    agent = put_in(agent.state.workflow, workflow)
    {agent, directives}
  end

  def handle_completion(agent, executed_runnable) do
    workflow = agent.state.workflow

    # Phase 3: Apply
    workflow = Runic.Workflow.apply_runnable(workflow, executed_runnable)

    {workflow, directives} =
      if Runic.Workflow.is_runnable?(workflow) do
        {workflow, runnables} = Runic.Workflow.prepare_for_dispatch(workflow)

        directives =
          Enum.map(runnables, fn runnable ->
            %JidoRunic.Directive.ExecuteRunnable{
              runnable_id: runnable.id,
              node: runnable.node,
              runnable: runnable
            }
          end)

        {workflow, directives}
      else
        # Workflow complete — emit leaf productions as signals
        productions = Runic.Workflow.raw_productions(workflow)

        directives =
          Enum.map(productions, fn value ->
            %Jido.Agent.Directive.Emit{
              signal: Jido.Signal.new!("runic.workflow.production", value, source: "/runic")
            }
          end)

        {workflow, directives}
      end

    agent = put_in(agent.state.workflow, workflow)
    {agent, directives}
  end
end
```

### What This Enables That Direct/FSM Cannot

| Capability | Direct | FSM | Runic Strategy |
|---|---|---|---|
| Linear action chain | Yes | Yes | Yes |
| State-driven transitions | No | Yes | Yes (StateMachine nodes) |
| Fan-out to parallel actions | No | No | Yes (FanOut + parallel branches) |
| Join / wait for N results | No | No | Yes (Join node) |
| Conditional branching | No | Per-state | Yes (Rule + Condition nodes) |
| Map-reduce over collections | No | No | Yes (Map/Reduce nodes) |
| DAG-based dependency resolution | No | No | Yes |
| Full provenance / audit trail | No | No | Yes (Fact ancestry) |
| Serializable execution state | No | No | Yes (build_log/from_log) |
| Runtime workflow modification | No | No | Yes (Workflow.add/3 at runtime) |

---

## Integration Point 4: Signal Gating via Runic Rules

### Problem

Not every signal should trigger every workflow path. Jido already has trie-based pattern matching for routing signals to actions. Runic has `Condition` and `Rule` nodes for gating execution. These should compose.

### Solution: `JidoRunic.SignalMatch` node

A Runic `:match` node that evaluates a Jido signal pattern against the input fact:

```elixir
defmodule JidoRunic.SignalMatch do
  @moduledoc """
  A Runic match node that gates downstream execution based on
  Jido signal type patterns. Uses prefix matching compatible
  with Jido's routing patterns.
  """

  defstruct [:name, :hash, :pattern]

  def new(pattern, opts \\ []) do
    name = opts[:name] || :"signal_match_#{pattern}"
    %__MODULE__{
      name: name,
      hash: :erlang.phash2({:signal_match, pattern}),
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
    else
      workflow
      |> Workflow.mark_runnable_as_ran(node, fact)
    end
  end

  def prepare(%JidoRunic.SignalMatch{} = node, workflow, fact) do
    context = CausalContext.new(
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
        Workflow.prepare_next_runnables(workflow, node, fact)
      else
        Workflow.mark_runnable_as_ran(workflow, node, fact)
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
```

### Usage: Multi-signal workflow with Join

```elixir
# Workflow that requires BOTH signals before proceeding
workflow = Runic.Workflow.new(name: :multi_signal_join)
  |> Workflow.add(JidoRunic.SignalMatch.new("order.paid", name: :paid_gate))
  |> Workflow.add(JidoRunic.SignalMatch.new("inventory.reserved", name: :reserved_gate))
  |> Workflow.add(
    ActionNode.new(MyApp.Actions.FulfillOrder, name: :fulfill),
    to: [:paid_gate, :reserved_gate]  # Join — waits for both
  )
```

This is something neither Jido's Direct nor FSM strategy can express: "wait for two independent signals, then fire an action."

---

## Integration Point 5: Workflow Productions → Jido Directives

### Problem

Runic workflows produce `%Fact{}` leaf values. Jido agents communicate effects as directives. There needs to be a clean boundary where one becomes the other.

### Design Principle

Runic leaf productions are **domain values**. A single explicit conversion step at the workflow boundary transforms them into Jido directives. This avoids "magic" where facts implicitly cause effects.

### Approach A: Explicit DirectiveBuilder node

```elixir
# Last node in the workflow produces directives
directive_step = Runic.step(fn result ->
  %Jido.Agent.Directive.Emit{
    signal: Jido.Signal.new!("order.fulfilled", result, source: "/runic/order_pipeline")
  }
end, name: :emit_fulfillment)

workflow = Runic.Workflow.new()
  |> Workflow.add(fulfill_action_node)
  |> Workflow.add(directive_step, to: :fulfill)
```

### Approach B: Strategy-level extraction

The strategy extracts `raw_productions/1` after workflow satisfaction and wraps them:

```elixir
productions = Workflow.raw_productions(workflow)

directives = Enum.flat_map(productions, fn
  %Jido.Agent.Directive.Emit{} = d -> [d]  # Already a directive
  value -> [%Jido.Agent.Directive.Emit{
    signal: Jido.Signal.new!("runic.production", value, source: "/runic")
  }]
end)
```

**Recommendation**: Start with Approach B (strategy-level) for simplicity. Move to Approach A when specific workflows need fine-grained control over which productions become which directive types.

---

## Guardrails and Risks

### Purity Violation in `cmd/2`

**Risk**: Calling `Jido.Exec.run/2` or `Invokable.execute/2` inside `cmd/2` when actions perform I/O breaks the pure-functional contract.

**Mitigation**: `cmd/2` only performs Phase 1 (prepare) and Phase 3 (apply). Phase 2 (execute) always happens behind directives, in the AgentServer's directive executor.

### Double-Retry Semantics

**Risk**: Both Jido's action runner (`Jido.Exec` with retries/backoff) and a hypothetical Runic-level retry could retry the same operation independently.

**Mitigation**: Pick one place for retries — Jido's action runner. Runic nodes should not implement retry logic. If a runnable fails, the Runic strategy should handle it (mark failed, optionally emit error directive) without re-dispatching.

### Serialization: Closures vs. Data

**Risk**: Runic's `build_log`/`from_log` serialization works with `^pinned` closures and AST. Jido actions are module-based. If `ActionNode` stores anonymous functions, serialization breaks.

**Mitigation**: `ActionNode` stores `{action_mod, params}` as data — never anonymous closures. The `source/1` implementation in `Component` protocol returns reconstructable AST:

```elixir
quote do
  JidoRunic.ActionNode.new(unquote(node.action_mod), unquote(Macro.escape(node.params)))
end
```

### Workflow Memory Growth

**Risk**: Long-running workflows accumulate facts and edges in the graph, growing memory.

**Mitigation**: Add periodic compaction — snapshot `build_log`, prune intermediate facts that aren't needed for active runnables. This can be triggered by a hook or a scheduled directive.

### Hash Stability Across Versions

**Risk**: Runic's content-addressable hashing is based on AST/function hashing. If hash computation changes between Runic versions, serialized `build_log` entries become incompatible.

**Mitigation**: Version the serialization format in `build_log`. Add a compatibility check in `from_log/1`.

---

## Recommended Build Order

### Phase 1: Foundation (1-2 days)

1. **`JidoRunic.ActionNode`** struct + `Invokable`, `Component`, `Transmutable` implementations
2. **`JidoRunic.SignalFact`** adapter (signal → fact, fact → signal)
3. **Tests**: ActionNode can be added to a Runic workflow, invoked with `react_until_satisfied`, and produces correct facts

### Phase 2: Strategy (2-3 days)

4. **`JidoRunic.Directive.ExecuteRunnable`** directive struct
5. **`JidoRunic.Strategy`** implementation with `handle_signal/2` and `handle_completion/2`
6. **Directive executor integration** in AgentServer for `ExecuteRunnable`
7. **Tests**: End-to-end signal → workflow → directive → execution → completion → final output

### Phase 3: Signal Routing (1 day)

8. **`JidoRunic.SignalMatch`** node with `Invokable` implementation
9. **Tests**: Multi-signal join workflows, conditional branching based on signal type

### Phase 4: Polish (1-2 days)

10. **Serialization round-trip** tests for workflows containing `ActionNode`s
11. **Error handling**: Failed runnables → error directives
12. **Documentation and examples**

---

## Example: Order Processing Agent

Putting it all together — an agent that uses a Runic workflow to process orders:

```elixir
defmodule MyApp.OrderAgent do
  use Jido.Agent,
    name: "order_processor",
    schema: [
      workflow: [type: :any, default: nil],
      order_id: [type: :string, default: nil]
    ]

  def on_init(agent, _opts) do
    workflow = build_order_workflow()
    {:ok, put_in(agent.state.workflow, workflow)}
  end

  defp build_order_workflow do
    require Runic
    alias JidoRunic.ActionNode

    validate = ActionNode.new(MyApp.Actions.ValidateOrder, name: :validate)
    check_inventory = ActionNode.new(MyApp.Actions.CheckInventory, name: :check_inventory)
    charge_payment = ActionNode.new(MyApp.Actions.ChargePayment, name: :charge_payment)
    fulfill = ActionNode.new(MyApp.Actions.FulfillOrder, name: :fulfill)

    Runic.Workflow.new(name: :order_processing)
    |> Runic.Workflow.add(validate)
    |> Runic.Workflow.add(check_inventory, to: :validate)
    |> Runic.Workflow.add(charge_payment, to: :validate)
    |> Runic.Workflow.add(fulfill, to: [:check_inventory, :charge_payment])  # Join
  end
end
```

This produces the following execution graph:

```
              ┌─── CheckInventory ───┐
              │                      │
  Validate ───┤                      ├─── FulfillOrder (Join)
              │                      │
              └─── ChargePayment ────┘
```

- `ValidateOrder` runs first
- `CheckInventory` and `ChargePayment` run in parallel (independent branches)
- `FulfillOrder` waits for both to complete (Join node)
- All with full provenance, serializable state, and directive-based execution

---

## Open Questions

1. **Package structure**: Separate `jido_runic` package, or integrated into one of the existing packages?
2. **Action context**: How should Jido's `context` (with `state`, `request_id`, etc.) flow through Runic's fact ancestry? Should it be a separate field on `CausalContext`?
3. **Workflow lifecycle**: Should workflows be per-request (created fresh, GC'd after completion) or long-lived (persisted in agent state across signals)?
4. **Error recovery**: When a Runic runnable fails, should the strategy emit a compensating workflow (saga pattern) or delegate to Jido's existing `on_error` action hooks?
5. **Nested workflows**: Can a Runic ActionNode's action itself contain/trigger another Runic workflow (workflow-of-workflows)?
