# Jido.Runic.Strategy — Architecture Design (v3)

> Code-verified against `runic` dep (`zw/runnability-rework`), `jido` (`Jido.Agent.Strategy`),
> and existing `_old/` implementation. Every API call, arity, struct field, and return type
> referenced below has been confirmed against the real source.

---

## Core Insight

Runic is an **agenda-driven planner** built on a Rete-inspired DAG. Facts flow into
working memory, eligible nodes fire, results produce new facts that trigger further
nodes. Joins wait for multiple inputs. Conditions gate execution. StateMachines
accumulate state across cycles.

The Jido Strategy's only job is to be the **scheduler adapter**: convert Runic's
symbolic runnables into Jido directives, dispatch them, and feed results back as
facts. `cmd/3` is pure. Execution is effectful. The workflow is the single source
of truth.

---

## Mental Model: Workflow as Working Memory

| Concept | Runic Equivalent | Strategy Role |
|---------|-----------------|---------------|
| Working memory | Facts in the graph | Feed facts in via `plan_eagerly/2` |
| Agenda | `:runnable` / `:matchable` edges | Read via `prepare_for_dispatch/1` |
| Fire rule | `Invokable.execute(node, runnable)` | Dispatch via directive |
| Assert result | `Workflow.apply_runnable(workflow, executed)` | Apply in `cmd/3` on completion |
| Drain orphans | `Workflow.plan_eagerly(workflow)` (arity-1) | Call after every apply |
| Check quiescence | `Workflow.is_runnable?(workflow)` | Determine idle vs waiting vs success |

Key behaviors:

- **Wait** — A Join node won't fire until all parent facts exist. No runnables are
  produced. The strategy returns `{agent, []}` and sits in `:waiting`. Not an error.

- **Branch** — Conditions and Rules with guards create divergent paths. Different
  facts trigger different subgraphs. The strategy doesn't choose; `plan_eagerly` does.

- **Accumulate** — StateMachine nodes maintain state across multiple input facts.
  `plan_eagerly/1` catches state-produced facts and activates downstream stateful
  matchers.

- **Fan out and reduce** — FanOut expands enumerables into parallel fact streams.
  FanIn aggregates them back. The strategy sees multiple runnables from a single
  apply and dispatches them all.

---

## Verified Runic API Surface

All arities and return types confirmed from `deps/runic/lib/workflow.ex`:

| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `plan_eagerly/2` | `(workflow, Fact \| raw)` | `workflow` | Feed new input fact into graph, activate match phase |
| `plan_eagerly/1` | `(workflow)` | `workflow` | Scan for orphaned produced facts, plan + activate matches |
| `prepare_for_dispatch/1` | `(workflow)` | `{workflow, [%Runnable{}]}` | Extract dispatchable runnables; calls `Invokable.prepare/3` |
| `apply_runnable/2` | `(workflow, runnable)` | `workflow` | Apply completed/skipped/failed runnable back to graph |
| `is_runnable?/1` | `(workflow)` | `boolean` | True if any `:runnable` or `:matchable` edges exist |
| `raw_productions/1` | `(workflow)` | `[term]` | Extract leaf fact values |
| `get_hooks/2` | `(workflow, node_hash)` | `{before, after}` | Get hook fns registered for a node |
| `apply_hook_fns/2` | `(workflow, [apply_fn])` | `workflow` | Apply deferred hook modifications |

### `apply_runnable/2` Dispatch Table

| Runnable Status | Behavior |
|-----------------|----------|
| `:completed` | Calls `apply_fn.(workflow)` |
| `:skipped` | Calls `apply_fn.(workflow)` |
| `:failed` | Calls `mark_runnable_as_ran(workflow, node, fact)` — **no error fact produced** |
| `:pending` | Returns workflow unchanged |

**Critical**: Failed runnables do NOT produce error facts. Runic only prevents re-firing
the failed node. Conditional fallback branches that activate on error facts require
**explicit error fact injection** by the Strategy or a custom node wrapper. See
[Failure Semantics](#failure-semantics) below.

### `plan_eagerly/1` — Why It Matters

`prepare_next_runnables` (called inside `apply_fn` closures) only handles **direct
downstream children** of the producing node. But after an apply:

- A Join may now have all required parent facts (from different branches)
- A StatefulMatcher may now match on a newly accumulated state
- A MemoryAssertion may now be satisfiable

`plan_eagerly/1` scans ALL produced/state_produced/reduced facts that lack
runnable/matchable/ran edges and plans them. Without this call after every apply,
cross-branch activations stall.

Runic's own `react/2` does NOT call `plan_eagerly/1` between cycles — it relies on
the `apply_fn` closures' `prepare_next_runnables`. This works for simple pipelines
but fails for join/stateful/cross-branch patterns in an external scheduler context.
The Strategy must call it explicitly.

---

## The Execution Loop

```
External signal → Strategy.cmd/3 (PURE)
  1. Convert signal data → Fact
  2. Workflow.plan_eagerly(workflow, fact)         # plan_eagerly/2
  3. Workflow.prepare_for_dispatch(workflow)        # → {workflow, [runnables]}
  4. For each runnable → build ExecuteRunnable directive
  5. Track runnable.id → runnable in pending map
  6. Return {agent_with_updated_workflow, directives}

DirectiveExec (EFFECTFUL)
  7. Invokable.execute(runnable.node, runnable) → %Runnable{}
  8. Wrap failures as Runnable.fail(runnable, reason)
  9. Send completion signal back to agent (always carries full Runnable)

Completion signal → Strategy.cmd/3 (PURE)
 10. Pop runnable from pending by id
 11. Workflow.apply_runnable(workflow, executed_runnable)
 12. Workflow.plan_eagerly(workflow)                # plan_eagerly/1 — catch orphans
 13. Workflow.prepare_for_dispatch(workflow)         # → {workflow, [new_runnables]}
 14. If new runnables → build directives, track pending, return
 15. If is_runnable? but no runnables prepared → :waiting (join not satisfied)
 16. If not is_runnable? → workflow quiesced → check for productions
```

### Step 12 is the critical addition vs v1

After `apply_runnable`, the workflow graph has new facts from the `apply_fn` closure.
Those facts may satisfy joins, match stateful conditions, or activate memory assertions
that `prepare_next_runnables` (inside the closure) didn't reach. `plan_eagerly/1`
walks all orphaned produced facts and activates eligible downstream nodes.

---

## What the Strategy Does NOT Do

The strategy never:

- Calls `Workflow.log_fact`, `draw_connection`, `mark_runnable_as_ran`, or
  `prepare_next_runnables` directly. These are internal to Runic's `apply_fn`
  closures captured on each `Runnable` during `Invokable.execute`.

- Converts Runnables to `%Jido.Instruction{}`. The Runnable is the unit of work.
  Converting to Instruction destroys the `apply_fn` closure that carries the exact
  graph mutation needed to advance the workflow. The directive carries the Runnable
  itself.

- Decides what to run next. `prepare_for_dispatch` decides. The strategy dispatches
  whatever Runic says is ready.

- Terminates on failure by default. See [Failure Semantics](#failure-semantics).

---

## Directive: ExecuteRunnable

One directive. It carries the Runnable, not an Instruction.

```elixir
defmodule Jido.Runic.Directive.ExecuteRunnable do
  @moduledoc """
  Execute a Runic Runnable via the Jido runtime.

  The strategy builds this from each runnable returned by
  `Workflow.prepare_for_dispatch/1`. The runtime executes the
  runnable via `Invokable.execute/2` and sends the result back
  as a completion signal.

  The executed Runnable carries its own `apply_fn` closure —
  the strategy applies it back to the workflow via
  `Workflow.apply_runnable/2`. No manual graph manipulation needed.
  """

  defstruct [:runnable_id, :runnable, :target]

  @type target :: :local | {:child, atom()} | {:pid, pid()}

  @type t :: %__MODULE__{
          runnable_id: integer(),
          runnable: Runic.Workflow.Runnable.t(),
          target: target()
        }
end
```

### Why Runnable, Not Instruction

Runic's three-phase model: **prepare → execute → apply**. The `Runnable` struct
is the carrier between all three phases:

- After `prepare`: holds `node`, `input_fact`, `context`, `status: :pending`
- After `execute`: holds `result`, `apply_fn`, `status: :completed` (or `:failed`/`:skipped`)
- During `apply`: `Workflow.apply_runnable` calls `apply_fn.(workflow)` which
  performs the exact graph mutations (log fact, draw connections, mark ran,
  prepare next runnables)

The `target` field determines where execution happens (see Multi-Agent below).

**Note**: The current `_old` directive struct uses `%{runnable_id, node, runnable}`
(no `target`). Phase 2 adds the `target` field.

---

## DirectiveExec Implementation

```elixir
defimpl Jido.AgentServer.DirectiveExec, for: Jido.Runic.Directive.ExecuteRunnable do
  def exec(%{runnable: runnable, target: :local} = _directive, _input_signal, state) do
    agent_pid = self()

    task_sup =
      if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor

    Task.Supervisor.start_child(task_sup, fn ->
      executed =
        try do
          Runic.Workflow.Invokable.execute(runnable.node, runnable)
        rescue
          e ->
            Runic.Workflow.Runnable.fail(runnable, Exception.message(e))
        catch
          kind, reason ->
            Runic.Workflow.Runnable.fail(runnable, "Caught #{kind}: #{inspect(reason)}")
        end

      # ALWAYS send back a full Runnable — never a bare {runnable_id, reason} tuple.
      # This ensures the Strategy can always call Workflow.apply_runnable/2.
      signal_type =
        case executed.status do
          :completed -> "runic.runnable.completed"
          :failed -> "runic.runnable.failed"
          :skipped -> "runic.runnable.completed"
        end

      signal = Jido.Signal.new!(
        signal_type,
        %{runnable: executed},
        source: "/runic/executor"
      )

      Jido.AgentServer.cast(agent_pid, signal)
    end)

    {:async, nil, state}
  end
end
```

### Contract: Always Return a Runnable

The `_old` implementation wraps exceptions as `{:error, reason}` tuples and sends
a `"runic.runnable.failed"` signal with `%{runnable_id: id, reason: reason}` — no
Runnable struct. This creates a split code path in the Strategy where failures bypass
`Workflow.apply_runnable/2`.

**V3 requirement**: The executor MUST always wrap failures via `Runnable.fail/2` and
send the full `%Runnable{}` back. The Strategy MUST always call
`Workflow.apply_runnable/2`, which handles all statuses uniformly.

---

## Failure Semantics

### What Runic Actually Does on Failure

`Workflow.apply_runnable/2` on a `%Runnable{status: :failed}` calls
`handle_failed_runnable/2`, which does exactly one thing:

```elixir
defp handle_failed_runnable(workflow, %Runnable{node: node, input_fact: fact, error: error}) do
  Logger.warning("Runnable failed for node #{inspect(node)} with error: #{inspect(error)}")
  mark_runnable_as_ran(workflow, node, fact)
end
```

It marks the node as ran (preventing re-fire) and logs a warning. **It does not**:
- Produce an error fact
- Activate any downstream conditional branches
- Terminate the workflow

### Strategy-Level Failure Handling

Since Runic doesn't produce error facts on failure, the Strategy must decide:

**Option A: Error fact injection (enables fallback branches)**

After applying a failed runnable, the Strategy can create an error fact and feed it
into the workflow:

```elixir
workflow = Workflow.apply_runnable(workflow, failed_runnable)

# Inject error fact so conditional branches can react
error_fact = Fact.new(
  value: %{error: failed_runnable.error, node: failed_runnable.node.name},
  ancestry: {failed_runnable.node.hash, failed_runnable.input_fact.hash}
)

workflow = Workflow.plan_eagerly(workflow, error_fact)
```

This lets you build resilient workflows where a Condition downstream fires on error
facts. The Strategy doesn't need to know about the fallback logic — it just injects
the error fact and lets Runic's DAG handle the rest.

**Option B: Terminal failure (simpler, current `_old` behavior)**

If no error fact injection, the Strategy checks after applying:
- If `is_runnable?` → continue (other branches still active)
- If not `is_runnable?` AND `pending` is empty AND no productions → terminal failure

**V3 design**: Implement Option A. The Strategy always injects error facts after
applying failed runnables, then calls `plan_eagerly/1` to activate any fallback
branches. Terminal failure only occurs when the workflow quiesces with no productions
after all paths (including error-triggered fallbacks) have been exhausted.

---

## Strategy State Shape

```elixir
%{
  workflow: %Runic.Workflow{},       # The single source of truth
  status: :idle | :running | :waiting | :success | :failure,
  pending: %{runnable_id => %Runnable{}},  # In-flight runnables awaiting completion
  max_concurrent: pos_integer() | :infinity,
  queued: [%Runnable{}]              # Excess runnables when max_concurrent hit
}
```

### Status Semantics

| Status | Meaning | Maps to Jido |
|--------|---------|--------------|
| `:idle` | No workflow activity. Waiting for input signal. | `:idle` |
| `:running` | Runnables dispatched, awaiting completions. | `:running` |
| `:waiting` | Workflow has pending edges (e.g., unsatisfied Join) but no dispatchable runnables. Waiting for an external signal to provide the missing fact. | `:waiting` |
| `:success` | Workflow quiesced with productions. Terminal. | `:success` |
| `:failure` | All paths exhausted with errors, no continuations possible. Terminal. | `:failure` |

**Note**: Jido's `StratState.set_status/2` only accepts `:idle | :running | :waiting |
:success | :failure`. The `_old` code incorrectly uses `:satisfied` and `:failed` —
these must be `:success` and `:failure`.

`:waiting` is the key status missing from v1/`_old`. A Join node that needs facts from
two different input signals will sit in `:waiting` between the first and second
signal. This is normal, not an error.

### Status Transitions

```
:idle → :running        # First runnables dispatched after feed
:running → :running     # Completion triggers new runnables
:running → :waiting     # Completion applied, but no new runnables; is_runnable? true
:running → :success     # No pending, not runnable, has productions
:running → :failure     # No pending, not runnable, no productions, had errors
:waiting → :running     # New signal feeds fact that satisfies join/condition
:waiting → :idle        # Timeout or reset (external)
```

---

## ActionNode: Required Fixes

The current `ActionNode` implementation has four discrepancies with Runic's built-in
node behavior. All must be fixed before Phase 2.

### Fix 1: apply_fn Ordering

Built-in Runic nodes (Step, FanIn, etc.) use this ordering in their `apply_fn`:

```
log_fact → draw_connection → prepare_next_runnables → mark_runnable_as_ran
```

Current ActionNode ordering (WRONG):

```
log_fact → draw_connection → mark_runnable_as_ran → prepare_next_runnables
```

`prepare_next_runnables` may check whether a node is already marked as ran. Marking
before preparing can prevent downstream activation. Swap the last two calls.

### Fix 2: Capture Hooks in prepare/3

Built-in nodes capture hooks during prepare:

```elixir
context = CausalContext.new(
  node_hash: node.hash,
  input_fact: fact,
  ancestry_depth: Workflow.ancestry_depth(workflow, fact),
  hooks: Workflow.get_hooks(workflow, node.hash)   # <-- missing from ActionNode
)
```

Without this, `attach_before_hook/3` and `attach_after_hook/3` on ActionNodes silently
do nothing.

### Fix 3: Run Hooks in execute/2

Built-in nodes use `HookRunner.run_before/3` and `HookRunner.run_after/4` during
execute, collecting deferred `apply_fn`s. These are applied in the main `apply_fn`
via `Workflow.apply_hook_fns/2`:

```elixir
def execute(%ActionNode{} = node, %Runnable{input_fact: fact, context: ctx} = runnable) do
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

      {:error, reason} ->
        Runnable.fail(runnable, reason)
    end
  else
    {:error, reason} ->
      Runnable.fail(runnable, {:hook_error, reason})
  end
end
```

### Fix 4: invoke/3 Should Delegate to apply_runnable

Current `invoke/3` manually calls `apply_fn.(workflow)` on success and only
`mark_runnable_as_ran` on failure. This duplicates and diverges from
`Workflow.apply_runnable/2` semantics (and ignores `:skipped`/`:pending` statuses).

Replace with:

```elixir
def invoke(%ActionNode{} = node, workflow, fact) do
  {:ok, runnable} = prepare(node, workflow, fact)
  executed = execute(node, runnable)
  Workflow.apply_runnable(workflow, executed)
end
```

---

## Strategy Implementation

### Signal Routes

```elixir
@impl true
def signal_routes(_ctx) do
  [
    {"runic.feed", {:strategy_cmd, :runic_feed_signal}},
    {"runic.runnable.completed", {:strategy_cmd, :runic_apply_result}},
    {"runic.runnable.failed", {:strategy_cmd, :runic_apply_result}},
    {"runic.set_workflow", {:strategy_cmd, :runic_set_workflow}}
  ]
end
```

**Change from v2/`_old`**: Both completed and failed runnables route to the same
handler (`:runic_apply_result`). Failed runnables now always carry a full `%Runnable{}`
and follow the same apply path. No separate `handle_failure` handler.

### init/2

```elixir
@impl true
def init(agent, ctx) do
  strategy_opts = ctx[:strategy_opts] || []

  workflow =
    case Keyword.get(strategy_opts, :workflow) do
      nil ->
        case Keyword.get(strategy_opts, :workflow_fn) do
          fun when is_function(fun, 0) -> fun.()
          _ -> nil
        end
      wf -> wf
    end

  strat_state = StratState.get(agent, nil)

  if strat_state && Map.get(strat_state, :workflow) do
    {agent, []}
  else
    strat = %{
      workflow: workflow || Workflow.new(:default),
      status: :idle,
      pending: %{},
      max_concurrent: Keyword.get(strategy_opts, :max_concurrent, :infinity),
      queued: []
    }

    {StratState.put(agent, strat), []}
  end
end
```

### cmd/3 — Feed Signal

```elixir
defp handle_instruction(agent, %Instruction{action: :runic_feed_signal, params: params}) do
  strat = StratState.get(agent)
  workflow = strat.workflow
  input = Map.get(params, :data, params)

  fact =
    case Map.get(params, :signal) do
      nil -> Fact.new(value: input, ancestry: nil)
      signal -> SignalFact.from_signal(signal)
    end

  workflow = Workflow.plan_eagerly(workflow, fact)
  {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

  {directives, strat} = dispatch_with_limit(runnables, strat)

  status =
    cond do
      directives != [] or map_size(strat.pending) > 0 -> :running
      Workflow.is_runnable?(workflow) -> :waiting
      true -> :idle
    end

  agent = StratState.put(agent, %{strat | workflow: workflow, status: status})
  {agent, directives}
end
```

### cmd/3 — Apply Result (Completed or Failed)

```elixir
defp handle_instruction(agent, %Instruction{action: :runic_apply_result, params: params}) do
  strat = StratState.get(agent)
  runnable = Map.get(params, :runnable)
  pending = Map.delete(strat.pending, runnable.id)

  # Step 11: Apply the runnable (works for completed, failed, skipped)
  workflow = Workflow.apply_runnable(strat.workflow, runnable)

  # Step 11.5: If failed, inject error fact for fallback branches
  workflow =
    if runnable.status == :failed do
      error_fact = Fact.new(
        value: %{error: runnable.error, node: runnable.node.name, status: :failed},
        ancestry: {runnable.node.hash, runnable.input_fact.hash}
      )
      Workflow.plan_eagerly(workflow, error_fact)
    else
      workflow
    end

  # Step 12: Catch orphaned facts (joins, stateful matchers, cross-branch)
  workflow = Workflow.plan_eagerly(workflow)

  # Step 13: Dispatch new runnables
  {workflow, new_runnables} = Workflow.prepare_for_dispatch(workflow)
  {directives, strat} = dispatch_with_limit(new_runnables, %{strat | pending: pending})

  # Step 14-16: Determine status
  status =
    cond do
      map_size(strat.pending) > 0 or directives != [] ->
        :running

      Workflow.is_runnable?(workflow) ->
        :waiting

      true ->
        productions = Workflow.raw_productions(workflow)
        if productions != [], do: :success, else: :failure
    end

  strat = %{strat | workflow: workflow, status: status}
  agent = StratState.put(agent, strat)

  # Emit productions on success
  directives =
    if status == :success do
      productions = Workflow.raw_productions(workflow)

      emit_directives =
        Enum.map(productions, fn value ->
          signal = Jido.Signal.new!("runic.workflow.production", value, source: "/runic")
          %Jido.Agent.Directive.Emit{signal: signal}
        end)

      directives ++ emit_directives
    else
      directives
    end

  {agent, directives}
end
```

### Snapshot

```elixir
@impl true
def snapshot(agent, _ctx) do
  strat = StratState.get(agent, %{})
  workflow = Map.get(strat, :workflow)
  status = Map.get(strat, :status, :idle)

  %Jido.Agent.Strategy.Snapshot{
    status: status,
    done?: status in [:success, :failure],
    result: if(status == :success and workflow, do: Workflow.raw_productions(workflow)),
    details: %{
      pending_count: map_size(Map.get(strat, :pending, %{})),
      queued_count: length(Map.get(strat, :queued, [])),
      is_runnable: workflow && Workflow.is_runnable?(workflow),
      productions_count:
        if(workflow, do: length(Workflow.raw_productions(workflow)), else: 0)
    }
  }
end
```

### Tick

`tick/2` handles recovery from missed signals and drains the concurrency queue:

```elixir
@impl true
def tick(agent, _ctx) do
  strat = StratState.get(agent, nil)

  cond do
    # Drain queued runnables if under concurrency limit
    strat && strat.queued != [] and map_size(strat.pending) < strat.max_concurrent ->
      {to_dispatch, remaining} =
        Enum.split(strat.queued, strat.max_concurrent - map_size(strat.pending))

      directives = Enum.map(to_dispatch, &build_directive/1)

      pending =
        Enum.reduce(to_dispatch, strat.pending, fn r, acc ->
          Map.put(acc, r.id, r)
        end)

      agent =
        StratState.put(agent, %{strat | pending: pending, queued: remaining})

      {agent, directives}

    # Check for stalled workflow — runnables exist but weren't dispatched
    strat && strat.status == :running and Workflow.is_runnable?(strat.workflow) ->
      {workflow, runnables} = Workflow.prepare_for_dispatch(strat.workflow)

      new =
        Enum.reject(runnables, &Map.has_key?(strat.pending, &1.id))

      {directives, strat} =
        dispatch_with_limit(new, %{strat | workflow: workflow})

      agent = StratState.put(agent, strat)
      {agent, directives}

    true ->
      {agent, []}
  end
end
```

---

## Concurrency Control

Fan-out workflows can produce many runnables simultaneously. Without limits,
this spawns unbounded tasks.

```elixir
defp dispatch_with_limit(runnables, state) do
  available =
    if state.max_concurrent == :infinity,
      do: length(runnables),
      else: max(state.max_concurrent - map_size(state.pending), 0)

  {to_dispatch, to_queue} = Enum.split(runnables, available)

  directives = Enum.map(to_dispatch, &build_directive/1)

  pending =
    Enum.reduce(to_dispatch, state.pending, fn r, acc ->
      Map.put(acc, r.id, r)
    end)

  {directives, %{state | pending: pending, queued: state.queued ++ to_queue}}
end

defp build_directive(runnable) do
  target =
    case runnable.node do
      %Jido.Runic.ActionNode{executor: {:child, tag}} -> {:child, tag}
      %Jido.Runic.ActionNode{executor: {:child, tag, _spec}} -> {:child, tag}
      _ -> :local
    end

  %Jido.Runic.Directive.ExecuteRunnable{
    runnable_id: runnable.id,
    runnable: runnable,
    target: target
  }
end
```

When a runnable completes and pending count drops below `max_concurrent`, `tick/2`
drains the queue.

---

## Multi-Agent Orchestration

### The Core Idea

The Runic DAG expresses *what* depends on *what*. The strategy decides *where*
each piece of work runs. A node's execution target is metadata on the node, not
a separate orchestration layer.

### ActionNode Gets an Executor Target

```elixir
defstruct [
  :name, :hash, :action_mod, :params, :context, :exec_opts,
  :inputs, :outputs,
  executor: :local  # :local | {:child, tag} | {:child, tag, spawn_spec}
]
```

### Joins Across Agents

```elixir
scout_a = ActionNode.new(ScoutAction, %{source: :twitter},
  executor: {:child, :scout_a, {ScoutAgent, []}})

scout_b = ActionNode.new(ScoutAction, %{source: :reddit},
  executor: {:child, :scout_b, {ScoutAgent, []}})

synthesize = ActionNode.new(SynthesizeAction, %{}, name: :synthesize)

workflow =
  Workflow.new(:multi_scout)
  |> Workflow.add(scout_a)
  |> Workflow.add(scout_b)
  |> Workflow.add(synthesize, to: [:scout_a, :scout_b])  # Join
```

When the parent agent receives `runic.feed`:

1. `plan_eagerly/2` activates both scouts
2. `prepare_for_dispatch` returns two runnables
3. Strategy emits two directives with `target: {:child, :scout_a}` / `{:child, :scout_b}`
4. Both children execute in parallel
5. First child completes → `apply_runnable` → `plan_eagerly/1` → Join not satisfied → `:waiting`
6. Second child completes → `apply_runnable` → `plan_eagerly/1` → Join satisfied → synthesize runnable
7. Strategy dispatches synthesize (locally or to another child)

The strategy didn't implement any join logic. Runic's DAG handled it.

---

## Comparison with Existing Strategies

| Aspect | ChainOfThought | Runic |
|--------|----------------|-------|
| Pure core | `Machine` struct (Fsmx) | `Runic.Workflow` (DAG) |
| State shape | Linear: idle → reasoning → done | Graph: arbitrary DAG with joins, fan-out, conditions |
| `cmd/3` purity | Pure — Machine.update emits symbolic directives | Pure — Workflow plan/apply/prepare, directives emitted |
| Execution | Via `Directive.LLMStream` | Via `Directive.ExecuteRunnable` |
| Multi-step | LLM call → parse → done | Arbitrary DAG cycles until quiescence |
| Parallelism | None | Native — multiple runnables dispatched concurrently |
| Waiting | Not supported | Native — Joins pause until all inputs arrive |
| Branching | Not supported | Native — Conditions/Rules gate paths |

### What to Copy from ChainOfThought

ChainOfThought is the right template for purity:

- Machine is the single source of truth for state transitions
- Strategy is a thin adapter: signal → machine message → machine update → lift directives
- Machine never does I/O; directives describe effects

Runic Strategy follows the same pattern:

- Workflow is the single source of truth
- Strategy is a thin adapter: signal → fact → workflow plan/apply → lift directives
- Workflow never does I/O; runnables describe work to be done

---

## Workflow Lifecycle Concerns

### Unbounded Growth

Long-running workflows accumulate facts and edges. Options:

1. **Compact on satisfaction**: Prune intermediate facts not referenced by pending joins
2. **Snapshot + rebuild**: Use `Workflow.build_log/1` / `Workflow.from_log/1` for persistence
3. **Workflow instances**: Create fresh workflow instances per input signal

### Serialization

The `Runnable.apply_fn` is a closure — it cannot be serialized. This means:

- Pending runnables must complete before the agent can be serialized/migrated
- For durable execution, Runic provides `Workflow.invoke_with_events/3` which returns
  serializable `%ReactionOccurred{}` events instead of closures
- The strategy should track whether it has in-flight runnables in its snapshot

---

## Signals

```elixir
# Input: external trigger to feed data into the workflow
"runic.feed"               → {:strategy_cmd, :runic_feed_signal}

# Completion: executed runnable returning (both success and failure carry full Runnable)
"runic.runnable.completed" → {:strategy_cmd, :runic_apply_result}
"runic.runnable.failed"    → {:strategy_cmd, :runic_apply_result}

# Dynamic workflow replacement
"runic.set_workflow"       → {:strategy_cmd, :runic_set_workflow}
```

**Change from v2**: `runic.runnable.failed` now routes to the same handler as
completed. The full `%Runnable{status: :failed}` is always present in the signal
payload, so the Strategy can call `apply_runnable/2` uniformly.

---

## Known Gaps in Current `_old` Implementation

| Gap | Current `_old` Behavior | V3 Required Behavior |
|-----|------------------------|---------------------|
| Status values | Uses `:satisfied`, `:failed` | Use `:success`, `:failure` (Jido contract) |
| `plan_eagerly/1` after apply | Not called | Must call after every `apply_runnable` |
| Failure handling | Terminal when pending empty; no `apply_runnable` on failures | Always apply failed runnables; inject error facts; check for continuations |
| `:waiting` status | Not implemented | Implement for join/cross-signal coordination |
| Concurrency control | Not implemented | `max_concurrent` + queue + tick drain |
| DirectiveExec failures | Sends `{runnable_id, reason}` tuple | Must send full `Runnable.fail(runnable, reason)` |
| Separate failure handler | `handle_failure/2` bypasses `apply_runnable` | Single `apply_result` handler for all statuses |
| Snapshot result | Always `nil` | Productions on `:success` |
| ActionNode hooks | Not captured or run | Capture in prepare, run via HookRunner in execute |
| ActionNode apply ordering | `mark_ran` before `prepare_next` | `prepare_next` before `mark_ran` |
| ActionNode invoke/3 | Manual apply_fn/mark_ran split | Delegate to `Workflow.apply_runnable/2` |

---

## Build Order

### Phase 1: ActionNode Fixes (done → needs corrections)
- [x] ActionNode struct + Invokable/Component/Transmutable impls
- [x] All tests passing
- [ ] **Fix apply_fn ordering** (prepare_next before mark_ran)
- [ ] **Capture hooks** in prepare/3 via `Workflow.get_hooks/2`
- [ ] **Run hooks** in execute/2 via `HookRunner.run_before/run_after`
- [ ] **Fix invoke/3** to delegate to `Workflow.apply_runnable/2`
- [ ] Add `executor` field (default `:local`)

### Phase 2: Strategy Core (2-3 days)
- [ ] `ExecuteRunnable` directive struct with `target` field
- [ ] `DirectiveExec` protocol impl — always returns `%Runnable{}` (failures via `Runnable.fail`)
- [ ] Strategy: `init/2`, `cmd/3` (feed + apply_result + set_workflow), `snapshot/2`, `tick/2`
- [ ] `signal_routes/1` — both completed/failed route to same handler
- [ ] `pending` tracking + `plan_eagerly/1` after every `apply_runnable`
- [ ] Error fact injection on failed runnables
- [ ] Status: `:idle → :running → :waiting → :success/:failure`
- [ ] Tests: single-node workflow end-to-end
- [ ] Tests: multi-node pipeline (verify `plan_eagerly/1` chains correctly)
- [ ] Tests: fan-out with concurrency limit
- [ ] Tests: Join that waits for two inputs across separate signals

### Phase 3: Failure & Resilience (1 day)
- [ ] Error fact injection activates conditional fallback branches
- [ ] Terminal failure only when no continuations exist and no productions
- [ ] Tests: workflow with fallback branch on failure
- [ ] Tests: all-paths-failed produces terminal `:failure`

### Phase 4: Multi-Agent (2 days)
- [ ] `executor` field on ActionNode (`:local | {:child, tag} | {:child, tag, spec}`)
- [ ] `DirectiveExec` for `{:child, tag}` targets (spawn + dispatch)
- [ ] Child completion signals routed back to parent strategy
- [ ] Tests: parent spawns child, child executes, result applied to parent workflow
- [ ] Tests: Join across two child agents

### Phase 5: Polish (1-2 days)
- [ ] Workflow compaction / instance management
- [ ] Introspection in snapshot (waiting nodes, join status)
- [ ] Documentation

---

## What We Dropped from v1

- **`to_instruction/2`** — Destroys Runnable's `apply_fn` closure
- **`RunInstruction` directive** — Replaced by `ExecuteRunnable`
- **`apply_completed_runnable/4`** — Manual graph manipulation; use `Workflow.apply_runnable`
- **`RunRunnableRemote` as a separate directive** — Merged into `ExecuteRunnable` with `target`
- **`EmitProductions` directive** — Productions emitted as standard `Directive.Emit`
- **Mode 1 (standalone)** — Use Runic directly with `react_until_satisfied`
- **Separate `handle_failure` handler** — All statuses go through `apply_result`

## What We Added vs v1

- **`:waiting` status** — Explicit representation of "join not satisfied, waiting for signal"
- **`plan_eagerly/1` after every apply** — Catches cross-branch/stateful activations
- **Error fact injection** — Strategy creates error facts so fallback branches can activate
- **Unified apply path** — All runnable statuses go through `Workflow.apply_runnable/2`
- **Concurrency control** — `max_concurrent` limit with queuing, drained via `tick`
- **Executor target on ActionNode** — First-class multi-agent support
- **Hook support in ActionNode** — Captures and runs Runic hooks like built-in nodes

## What We Corrected from v2

- **`plan_eagerly` arity** — v2 was ambiguous; v3 specifies `/1` after apply, `/2` on feed
- **Failure semantics** — v2 assumed Runic produces error facts; it doesn't. Strategy must inject them.
- **Status enum** — v2 used `:satisfied/:failed`; v3 uses `:success/:failure` (Jido contract)
- **`cmd` arity** — v2 said `cmd/2`; actual callback is `cmd/3`
- **ActionNode ordering** — v2 didn't flag the apply_fn ordering bug
- **ActionNode hooks** — v2 didn't flag the missing hook integration
- **DirectiveExec contract** — v2 showed correct code but `_old` impl diverges; v3 enforces "always return Runnable"
