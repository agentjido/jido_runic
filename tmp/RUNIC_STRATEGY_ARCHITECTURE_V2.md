# Jido.Runic.Strategy — Architecture Design (v2)

## Core Insight

Runic is not a pipeline. It is an **agenda-driven planner** built on a Rete-inspired
DAG. Facts flow into working memory, eligible nodes fire, results produce new facts
that trigger further nodes. Joins wait for multiple inputs. Conditions gate execution.
StateMachines accumulate state across cycles. The workflow decides *what* is ready;
the agent decides *where* and *when* to run it.

The Jido Strategy's only job is to be the **scheduler adapter**: convert Runic's
symbolic runnables into Jido directives, dispatch them, and feed results back as
facts. `cmd/2` is pure. Execution is effectful. The workflow is the single source
of truth.

---

## Mental Model: Workflow as Working Memory

Think of a Runic Workflow the way you'd think of a rule engine's working memory +
agenda, not a control-flow program:

| Concept | Runic Equivalent | Strategy Role |
|---------|-----------------|---------------|
| Working memory | Facts in the graph | Feed facts in via `plan_eagerly` |
| Agenda | `:runnable` / `:matchable` edges | Read via `prepare_for_dispatch` |
| Fire rule | `Invokable.execute(node, runnable)` | Dispatch via directive |
| Assert result | `Workflow.apply_runnable(workflow, executed)` | Apply in `cmd/2` on completion |
| Check quiescence | `Workflow.is_runnable?(workflow)` | Determine idle vs waiting vs satisfied |

This means:

- The workflow can **wait** — a Join node won't fire until all parent facts exist.
  No runnables are produced. The strategy returns `{agent, []}` and waits for the
  next signal. This is not an error; it's the workflow expressing a dependency.

- The workflow can **branch** — Conditions and Rules with guards create divergent
  paths. Different facts trigger different subgraphs. The strategy doesn't choose;
  `plan_eagerly` does.

- The workflow can **accumulate** — StateMachine nodes maintain state across multiple
  input facts. Each cycle may produce new state-produced facts that activate
  downstream stateful matchers.

- The workflow can **fan out and reduce** — FanOut expands enumerables into parallel
  fact streams. Reduce aggregates them back. The strategy sees multiple runnables
  from a single apply and dispatches them all.

---

## The Execution Loop

```
External signal → Strategy.cmd/2 (PURE)
  1. Convert signal data → Fact
  2. plan_eagerly(workflow, fact)
  3. prepare_for_dispatch(workflow) → {workflow, [runnables]}
  4. For each runnable → build ExecuteRunnable directive
  5. Track runnable.id → runnable in pending map
  6. Return {agent_with_updated_workflow, directives}

DirectiveExec (EFFECTFUL)
  7. Invokable.execute(runnable.node, runnable) → executed_runnable
  8. Send completion/failure signal back to agent

Completion signal → Strategy.cmd/2 (PURE)
  9. Pop runnable from pending by id
 10. Workflow.apply_runnable(workflow, executed_runnable)
 11. plan_eagerly(workflow) — pick up joins, conditions, next nodes
 12. prepare_for_dispatch(workflow) → {workflow, [new_runnables]}
 13. If new runnables → build directives, goto 4
 14. If is_runnable? but no runnables prepared → waiting (join not satisfied)
 15. If not is_runnable? → workflow satisfied → emit productions
```

### Why `plan_eagerly` After Every Apply

This is the critical detail the v1 doc missed. After `apply_runnable`, the workflow
graph has new facts. Those facts may:

- Satisfy a Join that was waiting for this + another input
- Match a Condition that gates a downstream branch
- Trigger a StateMachine's stateful matcher
- Activate a Rule whose guard now passes

`plan_eagerly` walks all unprocessed produced facts and activates any eligible
downstream nodes. Without this call, the workflow stalls after the first layer.

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

- Terminates on failure by default. A failed runnable is applied back to the
  workflow (Runic marks it as ran). If the workflow has fallback branches — a
  Condition downstream that fires on error facts — those activate naturally.
  The strategy only escalates to `Directive.Error` when the workflow has no valid
  continuation AND no pending runnables.

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
- After `execute`: holds `result`, `apply_fn`, `status: :completed` (or `:failed`)
- During `apply`: `Workflow.apply_runnable` calls `apply_fn.(workflow)` which
  performs the exact graph mutations (log fact, draw connections, mark ran,
  prepare next runnables)

Converting to `%Instruction{}` and back would require reconstructing the `apply_fn`
from scratch — reimplementing Runic's graph mutation logic inside the strategy.
That's semantic drift waiting to happen.

The `target` field determines where execution happens (see Multi-Agent below).

---

## DirectiveExec Implementation

```elixir
defimpl Jido.AgentServer.DirectiveExec, for: Jido.Runic.Directive.ExecuteRunnable do
  def exec(%{runnable: runnable, target: :local} = directive, _input_signal, state) do
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
        end

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

The executed Runnable — with its `apply_fn` intact — travels back to the strategy
via signal. No reconstruction needed. `cmd/2` calls `Workflow.apply_runnable` and
the workflow advances.

---

## Failure as Fact, Not Termination

When a Runnable fails:

1. `Invokable.execute` returns `%Runnable{status: :failed, error: reason}`
2. `Workflow.apply_runnable` calls `handle_failed_runnable` which marks the node
   as ran (so it won't re-fire) but does NOT terminate the workflow
3. The strategy calls `plan_eagerly` — if the workflow has conditional branches
   that handle errors, they activate
4. Only if `is_runnable?` returns false AND `pending_runnables` is empty AND the
   workflow is NOT satisfied → the strategy emits `Directive.Error`

This lets you build resilient workflows:

```elixir
# A workflow with a fallback branch
workflow =
  Workflow.new(:resilient)
  |> Workflow.add(risky_node)
  |> Workflow.add(fallback_node)  # Condition: fires when risky_node produces error fact
  |> Workflow.add(final_node, to: [:risky_node, :fallback_node])  # Join: either path
```

The strategy doesn't need to know about the fallback logic. Runic's DAG handles it.

---

## Strategy State Shape

```elixir
%{
  workflow: %Runic.Workflow{},       # The single source of truth
  status: :idle | :running | :waiting | :satisfied | :failed,
  pending: %{runnable_id => %Runnable{}},  # In-flight runnables awaiting completion
  max_concurrent: pos_integer() | :infinity,
  queued: [%Runnable{}]              # Excess runnables when max_concurrent hit
}
```

### Status Semantics

| Status | Meaning |
|--------|---------|
| `:idle` | No workflow activity. Waiting for input signal. |
| `:running` | Runnables dispatched, awaiting completions. |
| `:waiting` | Workflow has pending edges (e.g., unsatisfied Join) but no dispatchable runnables. Waiting for an external signal to provide the missing fact. |
| `:satisfied` | Workflow quiesced with productions. Terminal. |
| `:failed` | All paths exhausted with errors, no continuations possible. Terminal. |

`:waiting` is the key status missing from v1. A Join node that needs facts from
two different input signals will sit in `:waiting` between the first and second
signal. This is normal, not an error.

---

## Multi-Agent Orchestration

### The Core Idea

The Runic DAG expresses *what* depends on *what*. The strategy decides *where*
each piece of work runs. A node's execution target is metadata on the node, not
a separate orchestration layer.

### ActionNode Gets an Executor Target

```elixir
defmodule Jido.Runic.ActionNode do
  defstruct [
    :name, :hash, :action_mod, :params, :context, :exec_opts,
    :inputs, :outputs,
    executor: :local  # NEW: :local | {:child, tag} | {:child, tag, spawn_spec}
  ]
end
```

When the strategy converts runnables to directives, it reads the node's `executor`:

```elixir
defp build_directive(runnable) do
  target =
    case runnable.node do
      %ActionNode{executor: :local} -> :local
      %ActionNode{executor: {:child, tag}} -> {:child, tag}
      %ActionNode{executor: {:child, tag, _spec}} -> {:child, tag}
      _ -> :local
    end

  %ExecuteRunnable{
    runnable_id: runnable.id,
    runnable: runnable,
    target: target
  }
end
```

### DirectiveExec for Remote Targets

For `{:child, tag}` targets, the directive executor:

1. Checks if the child agent exists (via the agent's children map)
2. If not, spawns it via `Directive.SpawnAgent` (using the spawn spec from the node)
3. Serializes the runnable's essential context into a signal
4. Sends the signal to the child via `Directive.emit_to_pid`

The child executes the work and sends the result back to the parent via
`emit_to_parent`. The parent's strategy receives it as a `runic.runnable.completed`
signal and applies it normally.

### Joins Across Agents

This is where Runic's DAG shines. Consider:

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

When the parent agent receives `runic.input`:

1. `plan_eagerly` activates both scouts
2. `prepare_for_dispatch` returns two runnables
3. Strategy emits two `ExecuteRunnable` directives with `target: {:child, :scout_a}`
   and `target: {:child, :scout_b}`
4. Both children execute in parallel

When scout_a completes:

5. `apply_runnable` adds scout_a's result fact to the graph
6. `plan_eagerly` checks the Join — scout_b's fact is missing → no new runnables
7. Strategy status: `:waiting`

When scout_b completes:

8. `apply_runnable` adds scout_b's result fact
9. `plan_eagerly` checks the Join — both facts present → synthesize becomes runnable
10. `prepare_for_dispatch` returns the synthesize runnable
11. Strategy dispatches it (locally or to another child)

The strategy didn't implement any join logic. Runic's DAG handled it.

---

## Comparison with Existing Strategies

| Aspect | FSM | ChainOfThought | Runic |
|--------|-----|----------------|-------|
| Pure core | `Machine` struct | `Machine` (Fsmx-like) | `Runic.Workflow` (DAG) |
| State shape | Linear: idle → processing → done | Linear: idle → reasoning → done | Graph: arbitrary DAG with joins, fan-out, conditions, accumulation |
| `cmd/2` purity | **Violated** — calls `Jido.Exec.run` inline | Pure — Machine.update emits symbolic directives | Pure — Workflow.plan/apply/prepare, directives emitted |
| Execution | Inline in cmd/2 | Via `Directive.LLMStream` | Via `Directive.ExecuteRunnable` |
| Multi-step | Sequential instruction list | LLM call → parse → done | Arbitrary DAG cycles until quiescence |
| Parallelism | None | None | Native — multiple runnables dispatched concurrently |
| Waiting | Not supported | Not supported | Native — Joins pause until all inputs arrive |
| Branching | Not supported | Not supported | Native — Conditions/Rules gate paths |

### What to Copy from ChainOfThought

ChainOfThought is the right template for purity:

- Machine is the single source of truth for state transitions
- Strategy is a thin adapter: signal → machine message → machine update → lift directives
- Machine never does I/O; directives describe effects

Runic Strategy follows the same pattern:

- Workflow is the single source of truth
- Strategy is a thin adapter: signal → fact → workflow plan/apply → lift directives
- Workflow never does I/O; runnables describe work to be done

### What NOT to Copy from FSM

FSM calls `Jido.Exec.run` inside `cmd/3`. This violates purity and makes the
strategy untestable without mocking execution. Runic must never do this.

---

## Snapshot

```elixir
@impl true
def snapshot(agent, _ctx) do
  state = StratState.get(agent, %{})
  workflow = state.workflow

  %Jido.Agent.Strategy.Snapshot{
    status: state.status,
    done?: state.status in [:satisfied, :failed],
    result: if(state.status == :satisfied, do: Workflow.raw_productions(workflow)),
    details: %{
      pending_count: map_size(state.pending),
      queued_count: length(state.queued),
      is_runnable: Workflow.is_runnable?(workflow),
      productions_count: length(Workflow.raw_productions(workflow))
    }
  }
end
```

---

## Tick

`tick/2` handles recovery from missed signals and enforces timeouts:

```elixir
@impl true
def tick(agent, _ctx) do
  state = StratState.get(agent, %{})

  cond do
    # Drain queued runnables if under concurrency limit
    state.queued != [] and map_size(state.pending) < state.max_concurrent ->
      {to_dispatch, remaining} = Enum.split(state.queued,
        state.max_concurrent - map_size(state.pending))
      directives = Enum.map(to_dispatch, &build_directive/1)
      pending = Enum.reduce(to_dispatch, state.pending, fn r, acc ->
        Map.put(acc, r.id, r)
      end)
      agent = StratState.put(agent, %{state | pending: pending, queued: remaining})
      {agent, directives}

    # Check for stalled workflow — runnables exist but weren't dispatched
    state.status == :running and Workflow.is_runnable?(state.workflow) ->
      {workflow, runnables} = Workflow.prepare_for_dispatch(state.workflow)
      new = Enum.reject(runnables, &Map.has_key?(state.pending, &1.id))
      # ... dispatch new runnables

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
  available = state.max_concurrent - map_size(state.pending)

  {to_dispatch, to_queue} = Enum.split(runnables, max(available, 0))

  directives = Enum.map(to_dispatch, &build_directive/1)

  pending = Enum.reduce(to_dispatch, state.pending, fn r, acc ->
    Map.put(acc, r.id, r)
  end)

  {directives, %{state | pending: pending, queued: state.queued ++ to_queue}}
end
```

When a runnable completes and pending count drops below `max_concurrent`, `tick/2`
drains the queue.

---

## Workflow Lifecycle Concerns

### Unbounded Growth

Long-running workflows accumulate facts and edges. The workflow struct grows.
Options:

1. **Compact on satisfaction**: When the workflow reaches quiescence, prune
   intermediate facts not referenced by any pending join or production.
2. **Snapshot + rebuild**: Use `Workflow.build_log` / `Workflow.from_log` for
   persistence. The build log captures structure; facts can be replayed.
3. **Workflow instances**: For agents that run the same workflow repeatedly,
   create fresh workflow instances per input signal rather than reusing one.

### Serialization

The `Runnable.apply_fn` is a closure — it cannot be serialized. This means:

- Pending runnables must complete before the agent can be serialized/migrated
- For durable execution, use `Workflow.invoke_with_events` which returns
  serializable `ReactionOccurred` events instead of closures
- The strategy should track whether it has in-flight runnables in its snapshot

---

## Signals

```elixir
# Input: external trigger to feed data into the workflow
"runic.feed"          → {:strategy_cmd, :runic_feed_signal}

# Completion: executed runnable returning with apply_fn intact
"runic.runnable.completed" → {:strategy_cmd, :runic_apply_result}

# Failure: executed runnable that failed
"runic.runnable.failed"    → {:strategy_cmd, :runic_handle_failure}

# Dynamic workflow replacement
"runic.set_workflow"       → {:strategy_cmd, :runic_set_workflow}
```

---

## Build Order

### Phase 1: Foundation (done)
- [x] ActionNode struct + Invokable/Component/Transmutable impls
- [x] All tests passing

### Phase 2: Strategy Core (2-3 days)
- [ ] `ExecuteRunnable` directive struct with `target` field
- [ ] `DirectiveExec` protocol impl for local execution
- [ ] Strategy: `init`, `cmd` (feed + completed + failed), `snapshot`, `tick`
- [ ] `signal_routes` for all signal types
- [ ] `pending` tracking + `plan_eagerly` after every `apply_runnable`
- [ ] Status state machine: idle → running → waiting → satisfied/failed
- [ ] Tests: single-node workflow end-to-end
- [ ] Tests: multi-node pipeline (verify `plan_eagerly` chains correctly)
- [ ] Tests: fan-out with concurrency limit
- [ ] Tests: Join that waits for two inputs across separate signals

### Phase 3: Failure Handling (1 day)
- [ ] Failed runnables applied back to workflow (not terminal by default)
- [ ] Conditional fallback branches activate on failure
- [ ] Terminal failure only when no continuations exist
- [ ] Tests: workflow with fallback branch on failure
- [ ] Tests: all-paths-failed produces terminal error

### Phase 4: Multi-Agent (2 days)
- [ ] `executor` field on ActionNode (`:local | {:child, tag} | {:child, tag, spec}`)
- [ ] `DirectiveExec` for `{:child, tag}` targets (spawn + dispatch)
- [ ] Child completion signals routed back to parent strategy
- [ ] Tests: parent spawns child, child executes, result applied to parent workflow
- [ ] Tests: Join across two child agents

### Phase 5: Polish (1-2 days)
- [ ] Concurrency control (`max_concurrent` + queue + tick drain)
- [ ] Workflow compaction / instance management
- [ ] Production emission as signals on satisfaction
- [ ] Introspection in snapshot (waiting nodes, join status)
- [ ] Documentation

---

## What We Dropped from v1

- **`to_instruction/2`** — Destroys Runnable's `apply_fn` closure. The Runnable
  is the unit of work, not the Instruction.
- **`RunInstruction` directive** — Replaced by `ExecuteRunnable` which carries
  the Runnable directly.
- **`apply_completed_runnable/4`** — Manual graph manipulation that duplicates
  Runic internals. Use `Workflow.apply_runnable` directly.
- **`RunRunnableRemote` as a separate directive** — Merged into `ExecuteRunnable`
  with a `target` field. One directive, multiple execution targets.
- **`EmitProductions` directive** — Productions are emitted as standard
  `Directive.Emit` signals when the workflow reaches satisfaction. No special
  directive needed.
- **Mode 1 (standalone)** — Out of scope for `jido_runic`. Use Runic directly
  with `react_until_satisfied` if you don't need an agent.

## What We Added vs v1

- **`:waiting` status** — Explicit representation of "Join not yet satisfied,
  waiting for external signal." This is Runic's killer feature for multi-signal
  coordination and v1 had no concept of it.
- **`plan_eagerly` after every apply** — Without this, multi-layer workflows
  stall after the first layer. v1's `apply_result` didn't do this.
- **Failure as continuation, not termination** — Failed runnables feed back into
  the workflow so conditional branches can handle them.
- **Concurrency control** — `max_concurrent` limit with queuing, drained via `tick`.
- **Executor target on ActionNode** — First-class multi-agent support where the
  DAG itself expresses which agent runs each node.
