# JidoRunic Strategy V2 — Full AgentServer Integration

## Problem Statement

The current `JidoRunic.Strategy` implements the right abstractions — signal routing, runnable dispatch, result application — but it doesn't integrate with the AgentServer runtime the way `Jido.AI.Strategies.ReAct` does. The Studio pipeline works by manually calling `Strategy.execute_runnable/1` in a hand-rolled `execute_loop/3`. This means:

- `%ExecuteRunnable{}` directives hit the `DirectiveExec` `Any` fallback and get silently dropped in a real AgentServer
- No async execution — runnables block the calling process
- No signal-driven completion — results are applied synchronously, not via signals
- The pipeline can't run as a live agent that receives and responds to signals

ReAct solves this correctly. The strategy never executes anything. It emits directives. The AgentServer runtime executes them asynchronously. Results flow back as signals. The strategy processes them and emits more directives. Repeat until done.

## Reference: How ReAct Works

```
User sends Signal("react.input", %{query: "..."})
  │
  ▼
AgentServer receives signal
  │ signal_routes maps "react.input" → {:strategy_cmd, :react_start}
  ▼
Strategy.cmd(agent, [%Instruction{action: :react_start}])
  │ Machine.update(machine, {:start, query, call_id})
  │ Machine transitions idle → awaiting_llm
  ▼
Returns {agent, [%LLMStream{id: call_id, model: ..., context: ...}]}
  │
  ▼
AgentServer drains directive queue
  │ DirectiveExec.exec(%LLMStream{}, signal, state)
  │ Spawns async Task via Task.Supervisor
  │ Task streams LLM response
  │ Sends delta signals back: Signal("react.llm.delta", ...)
  │ Sends final: Signal("react.llm.response", %{call_id: ..., result: ...})
  ▼
AgentServer receives Signal("react.llm.response")
  │ signal_routes maps → {:strategy_cmd, :react_llm_result}
  ▼
Strategy.cmd(agent, [%Instruction{action: :react_llm_result}])
  │ Machine processes LLM response
  │ If tool calls: transitions → awaiting_tool
  │ If final answer: transitions → completed
  ▼
Returns {agent, [%ToolExec{...}, %ToolExec{...}]}  (or [] if done)
  │
  ▼
AgentServer drains directives
  │ Each ToolExec runs action async via Task.Supervisor
  │ Each sends back: Signal("react.tool.result", %{call_id: ..., result: ...})
  ▼
Strategy processes tool results, emits next LLM call
  │ ... loop continues until Machine reaches :completed
```

Key patterns:
- **Pure strategy**: `cmd/2` never executes side effects. It only updates state and emits directives.
- **Async execution**: All work (LLM calls, tool execution) runs in supervised Tasks.
- **Signal-driven loop**: Results flow back as signals via `AgentServer.cast(self(), signal)`.
- **`signal_routes/1`**: Maps signal types to strategy instruction atoms so routing is automatic.
- **`action_spec/1`**: Provides Zoi schemas for parameter normalization before `cmd/3` receives them.

## What V2 Needs

### 1. `DirectiveExec` for `ExecuteRunnable`

This is the critical missing piece. Without it, `%ExecuteRunnable{}` directives are silently dropped by the AgentServer.

```elixir
# lib/jido_runic/directive/execute_runnable_exec.ex

defimpl Jido.AgentServer.DirectiveExec, for: JidoRunic.Directive.ExecuteRunnable do
  alias Runic.Workflow.Invokable

  def exec(%{runnable_id: runnable_id, node: node, runnable: runnable}, _input_signal, state) do
    agent_pid = self()

    # Use Jido's standard task supervisor
    task_sup =
      if state.jido, do: Jido.task_supervisor_name(state.jido), else: Jido.TaskSupervisor

    Task.Supervisor.start_child(task_sup, fn ->
      executed = Invokable.execute(node, runnable)

      signal =
        case executed.status do
          :completed ->
            Jido.Signal.new!(
              "runic.runnable.completed",
              %{runnable: executed},
              source: "/runic/executor"
            )

          :failed ->
            Jido.Signal.new!(
              "runic.runnable.failed",
              %{runnable: executed, runnable_id: runnable_id, error: executed.error},
              source: "/runic/executor"
            )

          _ ->
            Jido.Signal.new!(
              "runic.runnable.completed",
              %{runnable: executed},
              source: "/runic/executor"
            )
        end

      Jido.AgentServer.cast(agent_pid, signal)
    end)

    {:async, nil, state}
  end
end
```

This mirrors exactly what `DirectiveExec` for `ToolExec` does:
1. Capture `self()` (the AgentServer pid)
2. Spawn async work in a supervised Task
3. Send result back as a signal via `AgentServer.cast`

The signal type (`"runic.runnable.completed"`) matches what `signal_routes/1` already maps to `:runic_apply_result`.

### 2. `action_spec/1` Callback

ReAct defines Zoi schemas for every instruction atom. This lets the AgentServer normalize parameters (string keys → atoms, type coercion) before the strategy receives them.

```elixir
# In JidoRunic.Strategy

@action_specs %{
  :runic_feed_signal => %{
    schema: Zoi.object(%{
      data: Zoi.any(),
      signal: Zoi.any() |> Zoi.optional()
    }),
    doc: "Feed a signal into the Runic workflow",
    name: "runic.feed_signal"
  },
  :runic_apply_result => %{
    schema: Zoi.object(%{
      runnable: Zoi.any()
    }),
    doc: "Apply a completed runnable result to the workflow",
    name: "runic.apply_result"
  },
  :runic_handle_failure => %{
    schema: Zoi.object(%{
      runnable_id: Zoi.integer(),
      reason: Zoi.any()
    }),
    doc: "Handle a failed runnable",
    name: "runic.handle_failure"
  },
  :runic_set_workflow => %{
    schema: Zoi.object(%{
      workflow: Zoi.any()
    }),
    doc: "Set the active workflow",
    name: "runic.set_workflow"
  }
}

@impl true
def action_spec(action), do: Map.get(@action_specs, action)
```

### 3. Adjust `apply_result` to Accept Signal Data

The current `apply_result/2` extracts `runnable` from params. But when the result arrives via a signal from the `DirectiveExec`, it comes as signal data `%{runnable: executed_runnable}`. The current code already does `Map.get(params, :runnable)`, so this should work as-is. But verify the signal data shape matches.

### 4. The Pipeline Becomes Trivial

Once `DirectiveExec` handles `ExecuteRunnable`, the Studio pipeline collapses to:

```elixir
def run_live(topic, opts \\ []) do
  workflow = build_strategy_workflow()

  # Start an AgentServer with the orchestrator agent
  {:ok, pid} = Jido.AgentServer.start(
    agent: OrchestratorAgent,
    id: "studio-#{topic}",
    strategy_opts: [workflow: workflow]
  )

  # Send the input signal — everything else is automatic
  signal = Jido.Signal.new!("runic.feed", %{
    data: %{topic: topic, audience: "general", num_queries: 3}
  }, source: "/studio/user")

  Jido.AgentServer.cast(pid, signal)

  # Poll for completion
  poll_until_done(pid)
end

defp poll_until_done(pid, timeout \\ 30_000) do
  deadline = System.monotonic_time(:millisecond) + timeout

  Stream.repeatedly(fn ->
    Process.sleep(100)
    Jido.AgentServer.snapshot(pid)
  end)
  |> Enum.find(fn snap ->
    snap.done? or System.monotonic_time(:millisecond) > deadline
  end)
end
```

No `execute_loop/3`. No manual `Strategy.execute_runnable/1`. No threading results back. The AgentServer runtime does it all.

## Architecture Comparison

### Current (V1): Manual Loop

```
Pipeline.run_strategy/2
  ├── Strategy.cmd(set_workflow)
  ├── Strategy.cmd(feed_signal) → [%ExecuteRunnable{}]
  ├── Strategy.execute_runnable(dir)     ← manual, blocking
  ├── Strategy.cmd(apply_result)         ← manual threading
  ├── Strategy.execute_runnable(dir)     ← manual, blocking
  ├── Strategy.cmd(apply_result)         ← manual threading
  └── ... until satisfied
```

Problems:
- Blocking execution — each runnable runs in the calling process
- No supervision — if a runnable crashes, the whole pipeline crashes
- No parallelism — fan-out runnables execute sequentially in `Enum.reduce`
- Test harness masquerading as production code

### Target (V2): AgentServer-Driven

```
AgentServer (GenServer)
  ├── Signal("runic.feed") arrives
  │   ├── signal_routes → {:strategy_cmd, :runic_feed_signal}
  │   ├── Strategy.cmd → {agent, [%ExecuteRunnable{}, ...]}
  │   └── Drain queue:
  │       ├── DirectiveExec.exec(%ExecuteRunnable{}) → Task.Supervisor.start_child
  │       └── DirectiveExec.exec(%ExecuteRunnable{}) → Task.Supervisor.start_child
  │                                                     (parallel!)
  ├── Signal("runic.runnable.completed") arrives (from Task)
  │   ├── signal_routes → {:strategy_cmd, :runic_apply_result}
  │   ├── Strategy.cmd → {agent, [%ExecuteRunnable{}, ...]} or {agent, [%Emit{...}]}
  │   └── Drain queue → dispatch next runnables or emit productions
  │
  └── ... continues until Strategy.status == :satisfied
```

Benefits:
- **Parallel fan-out**: Multiple `ExecuteRunnable` directives dispatch simultaneously
- **Supervised execution**: Tasks run under `Task.Supervisor`, crashes are isolated
- **Signal-driven**: No polling, no manual threading — the GenServer message loop does it
- **Observable**: Standard Jido signals for monitoring, tracing, pubsub
- **Composable**: Other agents can subscribe to production signals

## Implementation Plan

### Phase 1: DirectiveExec (the unlock)

| Task | File | Effort |
|------|------|--------|
| Implement `DirectiveExec` for `ExecuteRunnable` | `lib/jido_runic/directive/execute_runnable_exec.ex` | 1h |
| Add error wrapping (try/rescue/catch like ToolExec) | same file | 30min |
| Integration test: AgentServer + Strategy + real signal flow | `test/integration/agent_server_test.exs` | 2h |

### Phase 2: action_spec + param normalization

| Task | File | Effort |
|------|------|--------|
| Add `@action_specs` map with Zoi schemas | `lib/jido_runic/strategy.ex` | 30min |
| Implement `action_spec/1` callback | same file | 10min |
| Test normalization with string-keyed params | `test/jido_runic/strategy_test.exs` | 30min |

### Phase 3: Studio on AgentServer

| Task | File | Effort |
|------|------|--------|
| Add `Pipeline.run_live/2` using AgentServer | `lib/examples/studio/pipeline.ex` | 1h |
| Integration test: full pipeline via signals | `test/integration/studio_live_test.exs` | 2h |
| Keep `run_strategy/2` as the pure/functional test path | — | — |

### Phase 4: Production hardening

| Task | File | Effort |
|------|------|--------|
| Timeout handling in DirectiveExec (configurable per-node via ActionNode opts) | exec impl | 1h |
| Telemetry events (`:jido_runic, :runnable, :start/:complete/:fail`) | exec impl | 1h |
| Tracing context propagation (like ReAct's `TraceContext.propagate_to`) | exec impl | 30min |
| Max concurrent runnables (backpressure) | strategy.ex | 2h |

## Signal Types

| Signal Type | Direction | Mapped To | Purpose |
|-------------|-----------|-----------|---------|
| `runic.feed` | External → Agent | `:runic_feed_signal` | Feed input data into workflow |
| `runic.runnable.completed` | Task → Agent | `:runic_apply_result` | Completed runnable result |
| `runic.runnable.failed` | Task → Agent | `:runic_handle_failure` | Failed runnable error |
| `runic.workflow.production` | Agent → External | (Emit directive) | Final workflow output |
| `runic.set_workflow` | External → Agent | `:runic_set_workflow` | Replace the active workflow |

## Open Questions

1. **Should `DirectiveExec` live in jido_runic or jido?**
   It must live in `jido_runic` because it depends on `Runic.Workflow.Invokable`. The protocol dispatch is by struct type (`ExecuteRunnable`), which is defined in jido_runic. This is the same pattern as jido_ai: `DirectiveExec` for `LLMStream` and `ToolExec` lives in jido_ai, not jido core.

2. **Executor tag routing**: The `ExecuteRunnable` struct has an `executor_tag` field. In V2, should this control whether the runnable executes locally (Task) or gets dispatched to a child agent via `SpawnAgent`? For V2 Phase 1, always execute locally. Phase 4 can add child agent dispatch.

3. **Workflow persistence**: The workflow lives in `agent.state.__strategy__`. If the AgentServer restarts, the workflow is lost. For long-running workflows (supply chain, compliance), we'd need `build_log/from_log` serialization on agent state recovery. Out of scope for V2.

4. **Backpressure**: If a workflow has 100 parallel branches, should we limit concurrent Tasks? ReAct doesn't face this (1 LLM call at a time, N tool calls where N is small). Runic fan-out could be large. Consider a `:max_concurrent` option on the Strategy.

## Success Criteria

- [ ] `%ExecuteRunnable{}` directives execute asynchronously via `DirectiveExec`
- [ ] Results flow back as signals and re-enter `Strategy.cmd/3` automatically
- [ ] Fan-out runnables execute in parallel (multiple Tasks)
- [ ] Failed runnables send error signals, strategy handles them
- [ ] Studio pipeline runs end-to-end through AgentServer with only a single input signal
- [ ] `Pipeline.run_strategy/2` still works as pure functional test path
- [ ] No changes to jido core required
