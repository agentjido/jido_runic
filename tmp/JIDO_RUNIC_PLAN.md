# Jido Runic — Implementation Plan

## Vision

`jido_runic` is the bridge between Runic's DAG-based workflow engine and Jido's signal-driven agent framework. It enables something neither system can do alone: **multi-agent orchestration with formal graph execution, parallel fan-out/fan-in, join semantics, and end-to-end provenance** — all driven by Jido's pure `cmd/2` contract and directive-based effects.

---

## 5 Showcase Ideas

### 1. AI Research Studio (RECOMMENDED — see detailed design below)

An orchestrator agent coordinates a team of specialist AI agents to produce a fully-cited research article from a topic prompt. The Runic workflow manages the pipeline (plan queries → fan-out web research → extract claims → fan-out parallel section drafting → join → edit → quality gate → iterate). Every claim in the final article traces back through Runic Fact ancestry to the exact source document that produced it. Sub-agents are spawned via `SpawnAgent` directives and communicate results back via `emit_to_parent`.

**Why it's the best showcase:**
- Naturally exercises every Runic primitive: FanOut, FanIn, Join, Accumulator, Condition, react_until_satisfied
- Naturally exercises every Jido primitive: SpawnAgent, emit_to_parent, Signals, Actions, Strategy
- Provenance is a *visible product feature*, not just plumbing
- Can run in mock mode (deterministic stubs) or real mode (live LLM + web search)

### 2. Incident Commander — Autonomous SRE Response

An orchestrator reacts to alert signals, fans out to telemetry/log/deploy sub-agents in parallel, joins their findings, runs an LLM-powered root cause analysis, and executes remediation runbooks with Jido action retries and compensation. The Runic workflow enforces "don't mitigate until you have logs AND metrics AND deploy history" via Join nodes. Provenance chain: "this rollback happened because these specific log lines + this deploy diff."

**Unique value:** Join-gated remediation with audit-grade provenance for post-mortems.

### 3. Underwriting Swarm — Parallel Decisioning Saga

An orchestrator runs KYC, fraud, income, and credit checks as parallel Runic branches, each executed by a specialist agent. Join waits for all checks. A Condition node routes to human review if scores conflict. Saga compensation graph handles rollbacks if downstream steps fail (e.g., revoke offer if payment setup fails). Every "why was I denied?" question answered by provenance traversal.

**Unique value:** Saga compensation as a first-class Runic subgraph + regulatory audit trail.

### 4. Supply Chain Fulfillment — Long-Lived Workflow Across Real-World Events

An order fulfillment orchestrator waits on independent signals (payment, inventory, address verification) via SignalMatch + Join before purchasing shipping labels. Multi-warehouse fan-out with compensation (cancel losing reservations). Timeout branches for stuck customs clearance. Workflow persists across days via Runic's `build_log`/`from_log` serialization.

**Unique value:** Long-lived stateful workflow with real-world signal joins and snapshot/compaction.

### 5. Continuous Compliance Auditor — Living Evidence DAG

An orchestrator continuously collects evidence from cloud/CI/IAM sub-agents, validates SOC2/ISO controls via Runic Rules (each control requires multiple evidence facts joined), and spawns remediation agents for failures. Incremental recomputation: when evidence changes, only the affected subgraph re-runs. Provenance as the literal audit artifact.

**Unique value:** Incremental DAG recomputation + provenance graph IS the compliance report.

---

## Phase 1: Foundation Layer (Days 1-2)

Build the core integration primitives that all examples depend on.

### 1.1 `JidoRunic.ActionNode`

A custom Runic node type wrapping a Jido Action module, preserving action identity for stable hashing and serialization.

```
lib/jido_runic/action_node.ex
```

**Struct fields:**
- `name` — node name (atom/string)
- `hash` — content-addressed hash from `{action_mod, params, opts}`
- `action_mod` — the Jido Action module
- `params` — default params merged with input fact at execution
- `opts` — options (timeout, retry config, executor tag)
- `inputs` — derived from action schema (for Runic Component protocol)
- `outputs` — declared output schema

**Constructor:** `ActionNode.new(MyAction, %{default: "params"}, name: :my_step)`

**Protocol implementations:**

| Protocol | File | Purpose |
|----------|------|---------|
| `Runic.Workflow.Invokable` | `lib/jido_runic/action_node/invokable.ex` | 3-phase execution: prepare extracts Runnable, execute calls `Jido.Exec.run/2`, apply reduces result Fact back |
| `Runic.Component` | `lib/jido_runic/action_node/component.ex` | Graph composition: inputs/outputs, hash, connection logic |
| `Runic.Transmutable` | `lib/jido_runic/action_node/transmutable.ex` | `{ActionMod, params}` → ActionNode → single-node Workflow |

**Key design decisions:**
- Stores `{action_mod, params}` as data, never anonymous closures → serialization-safe
- `execute/2` delegates to `Jido.Exec.run/2` preserving retries, lifecycle hooks, validation
- `source/1` returns reconstructable AST via `quote do ... end`

### 1.2 `JidoRunic.SignalFact`

Bidirectional adapter between Jido Signals and Runic Facts.

```
lib/jido_runic/signal_fact.ex
```

**Functions:**
- `from_signal(signal)` — converts Signal → Fact, hashing `signal.source` + `signal.jidocause` into Fact ancestry
- `to_signal(fact, opts)` — converts Fact → Signal with configurable type and source

**Causality mapping:**

| Jido Signal | Runic Fact | Direction |
|-------------|-----------|-----------|
| `signal.id` | `fact.hash` | Content-addressed |
| `signal.source` | `fact.ancestry[0]` | Hashed into producer |
| `signal.jidocause` | `fact.ancestry[1]` | Hashed into parent |
| `signal.data` | `fact.value` | Direct |

### 1.3 Tests

```
test/jido_runic/action_node_test.exs
test/jido_runic/signal_fact_test.exs
```

- ActionNode can be added to a Runic Workflow
- ActionNode invoked with `react_until_satisfied` produces correct Facts
- SignalFact round-trips: Signal → Fact → Signal preserves data
- Ancestry chain is continuous across conversions

---

## Phase 2: Strategy + Directive Layer (Days 3-5)

### 2.1 `JidoRunic.Directive.ExecuteRunnable`

Custom directive struct for dispatching Runic Runnables.

```
lib/jido_runic/directive/execute_runnable.ex
```

**Fields:**
- `runnable_id` — unique ID for correlation
- `node` — the Runic node struct (ActionNode, Step, etc.)
- `runnable` — the full `%Runnable{}` struct
- `executor_tag` — optional atom indicating which child agent should execute

### 2.2 `JidoRunic.Strategy`

A `Jido.Agent.Strategy` implementation powered by a Runic Workflow DAG.

```
lib/jido_runic/strategy.ex
```

**Callbacks:**

| Callback | Behavior |
|----------|----------|
| `init/2` | Initialize workflow in `agent.state.__strategy__` |
| `cmd/3` | Route instructions to `handle_signal` or `handle_completion` |
| `tick/2` | Check for timed-out runnables, re-prepare if workflow still runnable |
| `snapshot/2` | Report workflow status, pending runnables count, satisfaction state |
| `signal_routes/1` | Route `runic.runnable.completed` and `runic.runnable.failed` signals |

**Core loop (inside cmd/3):**

```
Signal arrives
  → SignalFact.from_signal(signal)
  → Workflow.plan_eagerly(workflow, fact)
  → Workflow.prepare_for_dispatch(workflow) → {workflow, runnables}
  → Map runnables to [%ExecuteRunnable{...}] directives
  → Return {agent_with_updated_workflow, directives}

Completion signal arrives
  → Workflow.apply_runnable(workflow, executed_runnable)
  → If Workflow.is_runnable?(workflow) → prepare more directives
  → If satisfied → extract productions → convert to Emit directives
  → Return {agent, directives}
```

**Purity guarantee:** `cmd/2` only does Phase 1 (prepare) and Phase 3 (apply). Phase 2 (execute) happens in the AgentServer's directive executor, outside `cmd/2`.

### 2.3 Directive Executor Integration

The AgentServer needs to handle `%ExecuteRunnable{}` directives. Options:

**Option A (recommended):** The strategy converts `ExecuteRunnable` into standard Jido directives at the boundary:
- If executor_tag points to a child agent → `Directive.emit_to_pid(execute_signal, child_pid)`
- If no child exists → `Directive.spawn_agent(SpecialistAgent, tag)` + queue the runnable
- If local execution → execute via `Task` + emit completion signal back to self

**Option B:** Custom directive handler in AgentServer (requires jido core change).

Start with Option A — no core changes needed.

### 2.4 Tests

```
test/jido_runic/strategy_test.exs
test/jido_runic/directive/execute_runnable_test.exs
```

- End-to-end: signal → workflow → directive → execution → completion → final output
- Multi-step workflow with fan-out produces parallel ExecuteRunnable directives
- Join node waits for all branches before emitting next directives
- Failed runnable produces Error directive
- Workflow satisfaction terminates the loop

---

## Phase 3: Signal Routing (Day 6)

### 3.1 `JidoRunic.SignalMatch`

A Runic `:match` node that gates downstream execution based on Jido Signal type patterns.

```
lib/jido_runic/signal_match.ex
```

**Struct:** `%SignalMatch{name, hash, pattern}`
**Constructor:** `SignalMatch.new("order.paid", name: :paid_gate)`

**Invokable implementation:**
- `match_or_execute/1` → `:match`
- Checks if `fact.value.type` starts with `pattern`
- If match → prepare next runnables
- If no match → mark as ran (skip downstream)

### 3.2 Tests

```
test/jido_runic/signal_match_test.exs
```

- SignalMatch gates downstream execution based on signal type
- Multi-signal Join: workflow requires BOTH `order.paid` AND `inventory.reserved` before proceeding
- Conditional branching: different signal types route to different workflow branches

---

## Phase 4: Showcase Example — AI Research Studio (Days 7-10)

### Architecture

```
                           ┌─────────────────────────┐
                           │  Studio.Orchestrator     │
                           │  Strategy: RunicStrategy │
                           │  Owns: Runic Workflow    │
                           └────────┬────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
            ┌───────▼──────┐ ┌─────▼─────┐ ┌──────▼───────┐
            │ SourceScout  │ │  Writer   │ │   Editor     │
            │ (child agent)│ │(child x N)│ │ (child agent)│
            └──────────────┘ └───────────┘ └──────────────┘
```

### The Runic Workflow DAG

```
studio.request
    │
    ▼
[PlanQueries] ─── Step (LLM: generate search queries + outline seed)
    │
    ▼
[QueriesFanOut] ─── FanOut (spread queries into parallel branches)
    │
    ├──▶ [SearchAndFetch] ─── ActionNode (SourceScoutAgent)
    ├──▶ [SearchAndFetch] ─── ActionNode (SourceScoutAgent)
    └──▶ [SearchAndFetch] ─── ActionNode (SourceScoutAgent)
              │
              ▼
       [SourcesAccumulator] ─── Accumulator (collect + dedupe by URL)
              │
              ▼
       [ExtractClaims] ─── ActionNode (ClaimExtractorAgent, per source)
              │
              ▼
       [ClaimsAccumulator] ─── Accumulator (collect claims, index by tag)
              │
              ▼
       [BuildOutline] ─── Step (LLM: structured outline from claims)
              │
              ▼
       [SectionsFanOut] ─── FanOut (spread sections)
              │
              ├──▶ [DraftSection] ─── ActionNode (SectionWriterAgent)
              ├──▶ [DraftSection] ─── ActionNode (SectionWriterAgent)
              └──▶ [DraftSection] ─── ActionNode (SectionWriterAgent)
                        │
                        ▼
                 [DraftsFanIn] ─── FanIn (collect all section drafts)
                        │
                        ▼
                 [EditAndAssemble] ─── ActionNode (EditorAgent)
                        │
                        ▼
                 [QualityGate] ─── Condition (min sources, min citations)
                        │
                   ┌────┴────┐
                   │ PASS    │ FAIL → [DiagnoseGaps] → loop back
                   ▼
            [PublishResult] ─── Step (emit studio.article.ready)
```

### Agent Definitions

#### `Studio.OrchestratorAgent`

```elixir
defmodule Studio.OrchestratorAgent do
  use Jido.Agent,
    name: "studio_orchestrator",
    strategy: JidoRunic.Strategy,
    schema: [
      topic: [type: :string, default: nil],
      status: [type: :atom, default: :idle]
    ]
end
```

Owns the Runic Workflow. On `studio.request`, feeds the signal as a Fact into the workflow. The RunicStrategy handles the rest — preparing runnables, emitting `ExecuteRunnable` directives (which become `SpawnAgent` + `Emit` directives to child agents), and applying results as they come back.

#### `Studio.SourceScoutAgent`

```elixir
defmodule Studio.SourceScoutAgent do
  use Jido.Agent,
    name: "source_scout",
    schema: [query: [type: :string, default: nil]]
end
```

Receives a search query signal, executes `Studio.Actions.WebSearch` (mock or real), returns `%SourceDoc{url, title, content, retrieved_at}` via `emit_to_parent`.

#### `Studio.SectionWriterAgent`

```elixir
defmodule Studio.SectionWriterAgent do
  use Jido.Agent,
    name: "section_writer",
    schema: [section_id: [type: :string, default: nil]]
end
```

Receives a section spec + relevant claims, executes `Studio.Actions.DraftSection` (LLM call), returns `%SectionDraft{section_id, markdown, citations, used_claim_hashes}` via `emit_to_parent`.

#### `Studio.EditorAgent`

```elixir
defmodule Studio.EditorAgent do
  use Jido.Agent,
    name: "editor",
    schema: [mode: [type: :atom, default: :full_edit]]
end
```

Receives all drafts + sources + claims, executes `Studio.Actions.EditAndAssemble` (LLM call for coherence/style/transitions), returns `%Article{markdown, citations, quality_score}` via `emit_to_parent`.

### Actions

All actions use `use Jido.Action` with proper schema validation:

| Action | Input Schema | Output | Side Effects |
|--------|-------------|--------|--------------|
| `Studio.Actions.PlanQueries` | `%{topic, audience, format}` | `%{queries: [...], outline_seed: ...}` | LLM call |
| `Studio.Actions.WebSearch` | `%{query}` | `%SourceDoc{url, title, content}` | HTTP/mock |
| `Studio.Actions.ExtractClaims` | `%{source_doc}` | `[%Claim{text, quote, url, confidence}]` | LLM call |
| `Studio.Actions.BuildOutline` | `%{claims_summary, topic}` | `%Outline{sections: [...]}` | LLM call |
| `Studio.Actions.DraftSection` | `%{section_spec, relevant_claims}` | `%SectionDraft{markdown, citations}` | LLM call |
| `Studio.Actions.EditAndAssemble` | `%{drafts, sources, claims}` | `%Article{markdown, quality_score}` | LLM call |

### Signal Flow

```
User → studio.request → Orchestrator
  Orchestrator (RunicStrategy):
    1. plan_eagerly(workflow, request_fact)
    2. prepare_for_dispatch → [PlanQueries runnable]
    3. Emit ExecuteRunnable → execute locally or via child

  PlanQueries completes → runic.runnable.completed
    4. apply_runnable → workflow advances
    5. prepare_for_dispatch → [SearchAndFetch x N runnables]
    6. SpawnAgent(SourceScoutAgent, :scout_1) + Emit(execute_signal)
       SpawnAgent(SourceScoutAgent, :scout_2) + Emit(execute_signal)
       SpawnAgent(SourceScoutAgent, :scout_3) + Emit(execute_signal)

  Each scout completes → child.result signal → emit_to_parent
    7. apply_runnable for each → accumulator collects
    8. When all sources in → prepare ExtractClaims runnables
    ... continues through the DAG ...

  QualityGate passes:
    N. PublishResult → Emit(studio.article.ready, article + provenance)
```

### Provenance Demo

The killer feature — trace any claim in the final article:

```
Article Section 3, paragraph 2, claim: "Elixir processes are 2KB"
  ↓ SectionDraft fact (ancestry → DraftSection node)
    ↓ Claim fact: "Elixir processes are lightweight at ~2KB"
      ↓ ExtractClaims node (ancestry → SourceDoc fact)
        ↓ SourceDoc fact: {url: "https://elixir-lang.org/...", quote: "..."}
          ↓ SearchAndFetch node (ancestry → SearchQuery fact)
            ↓ SearchQuery: "elixir process memory overhead"
              ↓ PlanQueries node (ancestry → Request fact)
                ↓ Original request: "Write about Elixir concurrency"
```

Every hop is a Runic Fact with `ancestry: {producer_hash, parent_fact_hash}`.

### Mock Mode

All actions support a mock mode for running without API keys:

```elixir
defmodule Studio.Actions.WebSearch do
  use Jido.Action,
    name: "web_search",
    schema: [query: [type: :string, required: true]]

  def run(%{query: query}, _context) do
    if Application.get_env(:studio, :mock_mode, true) do
      {:ok, Studio.Fixtures.source_doc_for(query)}
    else
      # Real web search via Req/API
    end
  end
end
```

---

## Phase 5: Polish (Days 11-12)

### 5.1 Serialization Round-Trip

- `ActionNode` serializes via `source/1` AST (no closures)
- Test: `build_log` → `from_log` → workflow reconstructed with same hashes
- Test: workflow with mixed Steps + ActionNodes serializes correctly

### 5.2 Error Handling

- Failed runnable → `Runnable.fail(runnable, reason)` → strategy emits `Directive.Error`
- Timeout handling via `tick/2` — strategy schedules ticks to check for stuck runnables
- Max iteration guard on `react_until_satisfied` loop

### 5.3 Workflow Introspection

```elixir
defmodule JidoRunic.Introspection do
  def provenance_chain(workflow, fact_hash) do
    # Walk Fact ancestry back through the DAG
    # Returns [{fact, producing_node}, ...]
  end

  def execution_summary(workflow) do
    # Return %{total_nodes, completed, pending, failed, facts_produced}
  end
end
```

### 5.4 Documentation

- README with quick-start example
- Hex docs with architecture diagram
- Studio example as a runnable Mix project in `examples/studio/`

---

## File Structure

```
projects/jido_runic/
├── lib/
│   ├── jido_runic.ex                          # Top-level module + convenience API
│   ├── jido_runic/
│   │   ├── action_node.ex                     # ActionNode struct
│   │   ├── action_node/
│   │   │   ├── invokable.ex                   # Invokable protocol impl
│   │   │   ├── component.ex                   # Component protocol impl
│   │   │   └── transmutable.ex                # Transmutable protocol impl
│   │   ├── signal_fact.ex                     # Signal ↔ Fact adapter
│   │   ├── signal_match.ex                    # Signal type gating node
│   │   ├── signal_match/
│   │   │   └── invokable.ex                   # Invokable protocol impl
│   │   ├── strategy.ex                        # Jido.Agent.Strategy impl
│   │   ├── directive/
│   │   │   └── execute_runnable.ex            # Custom directive struct
│   │   ├── introspection.ex                   # Provenance queries
│   │   └── error.ex                           # Existing error module
│   └── studio/                                # Showcase example
│       ├── orchestrator_agent.ex
│       ├── source_scout_agent.ex
│       ├── section_writer_agent.ex
│       ├── editor_agent.ex
│       ├── actions/
│       │   ├── plan_queries.ex
│       │   ├── web_search.ex
│       │   ├── extract_claims.ex
│       │   ├── build_outline.ex
│       │   ├── draft_section.ex
│       │   └── edit_and_assemble.ex
│       ├── schemas/                           # Typed structs for facts
│       │   ├── source_doc.ex
│       │   ├── claim.ex
│       │   ├── outline.ex
│       │   ├── section_draft.ex
│       │   └── article.ex
│       └── fixtures.ex                        # Mock data for testing
├── test/
│   ├── jido_runic/
│   │   ├── action_node_test.exs
│   │   ├── signal_fact_test.exs
│   │   ├── signal_match_test.exs
│   │   ├── strategy_test.exs
│   │   └── introspection_test.exs
│   ├── studio/
│   │   ├── orchestrator_test.exs              # End-to-end showcase test
│   │   └── actions_test.exs
│   ├── support/
│   │   └── test_actions.ex                    # Simple test action modules
│   └── test_helper.exs
```

---

## Dependency Graph

```
jido_runic
├── jido (agents, actions, signals, directives)
│   ├── jido_action
│   └── jido_signal
├── runic (workflow DAG, invokable, facts, 3-phase execution)
│   └── libgraph
└── (optional) jido_ai / jido_chat (for real LLM calls in Studio example)
```

---

## Open Questions (To Resolve During Build)

1. **Executor routing:** How does the strategy decide which child agent executes a given runnable? Node metadata tag? ActionNode option? Convention-based?
   - **Proposed:** `ActionNode.new(MyAction, %{}, executor: :source_scout)` — the `executor` option maps to a SpawnAgent tag.

2. **Workflow lifecycle:** Per-request (fresh workflow, GC'd after completion) or long-lived (persisted in agent state)?
   - **Proposed:** Per-request for the Studio example. Long-lived workflows addressed in Phase 5 via serialization.

3. **Action context flow:** How does Jido's `context` (with `state`, `request_id`) flow through Runic?
   - **Proposed:** Merge into `CausalContext.meta` field on the Runnable. ActionNode's `execute/2` extracts it and passes as the context arg to `Jido.Exec.run/2`.

4. **Nested workflows:** Can an ActionNode trigger another Runic workflow?
   - **Proposed:** Yes — the child agent can itself use `JidoRunic.Strategy`. The parent workflow just sees it as a normal runnable that takes time and returns a result fact.

5. **Retry ownership:** Jido action runner or Runic level?
   - **Decided:** Jido action runner only. Runic nodes do not retry. Failed runnables emit error directives.

---

## Success Criteria

- [ ] `ActionNode` can wrap any `Jido.Action` and execute inside a Runic Workflow
- [ ] `SignalFact` preserves causality across Signal ↔ Fact boundaries
- [ ] `JidoRunic.Strategy` drives a multi-step workflow entirely through `cmd/2` purity
- [ ] Fan-out produces parallel `ExecuteRunnable` directives
- [ ] Join waits for all branches before advancing
- [ ] `react_until_satisfied` loop with QualityGate condition works end-to-end
- [ ] Studio example runs in mock mode with `mix run`
- [ ] Provenance chain is queryable: given any leaf Fact, trace back to root input
- [ ] All tests pass, `mix quality` passes
- [ ] No closures stored in ActionNode — serialization round-trip works
