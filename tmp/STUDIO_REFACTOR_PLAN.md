# Studio Example Refactor Plan

## Problem

The studio example has three competing execution paths that all bypass the agent:

| Path | Location | Problem |
|------|----------|---------|
| `Pipeline.run/2` | pipeline.ex:59-138 | Manual stage-by-stage, no strategy, no AgentServer |
| `Pipeline.run_strategy/2` | pipeline.ex:189-242 | Manual `execute_loop`, blocking, no supervision |
| `Pipeline.run_live/2` | pipeline.ex:252-324 | AgentServer but polls with `Process.sleep(100)` |

The OrchestratorAgent is a 7-line empty shell. The WebSearch action asks an LLM to pretend to be a search engine. None of this demonstrates how Jido actually works.

## Target

```elixir
result = OrchestratorAgent.run("Elixir Concurrency", mock: true)
# => %{topic: ..., productions: [...], facts: [...], status: :completed, events: [...]}
```

One call. The agent owns everything. Debug semantics for observability.

---

## Changes

### 1. Strategy sets top-level completion status

**File:** `projects/jido_runic/lib/jido_runic/strategy.ex`
**Depends on:** Nothing

`AgentServer.await_completion/2` checks `agent.state.status` for `:completed` / `:failed`. The strategy currently only sets status inside `agent.state.__strategy__` via `StratState.put`.

**Satisfied path** (around line 190, the `else` branch of `apply_result`):
- After setting strategy status to `:satisfied`, also do:
  ```elixir
  agent = put_in(agent.state.status, :completed)
  agent = put_in(agent.state.last_answer, productions)
  ```

**Failed path** (around lines 148 and 216, terminal failure in `apply_result` and `handle_failure`):
- After setting strategy status to `:failed`, also do:
  ```elixir
  agent = put_in(agent.state.status, :failed)
  agent = put_in(agent.state.error, reason)
  ```

This unlocks event-driven waiting via `await_completion` — no more polling.

**Tests:** Existing strategy tests (`test/jido_runic/strategy_test.exs`) should verify that `agent.state.status` is set alongside `agent.state.__strategy__.status`.

---

### 2. OrchestratorAgent gets `run/2`

**File:** `projects/jido_runic/lib/examples/studio/orchestrator_agent.ex`
**Depends on:** Change 1 (await_completion needs `:completed` status)

Expand from 7 lines to ~60. Add a single public function:

```elixir
def run(topic, opts \\ [])
```

Implementation steps inside `run/2`:

1. `Application.put_env(:jido_runic, :studio_mock_mode, opts[:mock] != false)`
2. `workflow = Pipeline.build_strategy_workflow()`
3. Start a Jido instance — caller can pass `:jido` opt, otherwise start a temporary one
4. `AgentServer.start_link(agent: __MODULE__, jido: jido, debug: true)`
5. `AgentServer.call(pid, Signal.new!("runic.set_workflow", %{workflow: workflow}, ...))`
6. `AgentServer.cast(pid, Signal.new!("runic.feed", %{data: %{topic: topic, audience: "general", num_queries: 3}}, ...))`
7. `AgentServer.await_completion(pid, timeout: opts[:timeout] || 30_000)` — event-driven, no polling
8. `AgentServer.state(pid)` → extract `StratState.get(agent)` → workflow → facts + productions
9. `AgentServer.recent_events(pid)` → attach debug events to result
10. Return result map:

```elixir
%{
  topic: topic,
  productions: Workflow.raw_productions(workflow),
  facts: Workflow.facts(workflow),
  status: strat.status,
  events: events,
  pid: pid
}
```

This mirrors the `ReActAgent.ask_sync` pattern but adapted for Runic workflows. The `debug: true` flag enables the internal event buffer so callers can inspect what happened.

---

### 3. Pipeline collapses to workflow definition

**File:** `projects/jido_runic/lib/examples/studio/pipeline.ex`
**Depends on:** Change 2 (execution moves to agent)

**Keep:**
- `build_strategy_workflow/0` — the DAG definition, this is the valuable part
- `article/1` — convenient result extraction helper, costs nothing
- `trace_provenance/2` + `do_trace/3` — useful Runic utility

**Remove:**
- `run/2` — manual stage-by-stage execution (V0 path)
- `run_strategy/2` + `execute_loop/3` — manual strategy loop (V1 path)
- `run_live/2` + `poll_until_done/2` — polling AgentServer (V2 draft, superseded by `await_completion`)
- `build_stages/0` — only used by `run/2`
- `build_workflow/0` — only used by one test, trivial
- `run_stage/3` — only used by `run/2`
- `print_summary/1` — replaced by debug events

**Remove unused aliases:** `Strategy`, `ExecuteRunnable`, `StratState` — no longer referenced once execution code is removed.

---

### 4. WebSearch uses jido_browser at runtime

**File:** `projects/jido_runic/lib/examples/studio/actions.ex` (WebSearch module, lines 91-132)
**Depends on:** Nothing (independent of changes 1-3)

The current "live" path asks an LLM to role-play as a search engine. Replace with real browser:

```elixir
def run(%{query: query}, _context) do
  if Helpers.mock_mode?() do
    {:ok, Map.from_struct(Fixtures.source_doc_for(query))}
  else
    if Code.ensure_loaded?(JidoBrowser) do
      browser_search(query)
    else
      {:error, "jido_browser not available — use mock: true or add jido_browser to deps"}
    end
  end
end

defp browser_search(query) do
  {:ok, session} = JidoBrowser.start_session()
  try do
    url = "https://html.duckduckgo.com/html/?q=#{URI.encode_www_form(query)}"
    {:ok, session, _} = JidoBrowser.navigate(session, url)
    {:ok, _session, %{content: content}} = JidoBrowser.extract_content(session, format: :markdown)
    {:ok, %{
      url: url,
      title: "Search: #{query}",
      content: content,
      snippet: String.slice(content, 0, 200),
      retrieved_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }}
  after
    JidoBrowser.end_session(session)
  end
end
```

**No dependency change** — `jido_browser` is NOT added to `jido_runic/mix.exs`. It's available at runtime in the workspace because both projects compile together. Guarded with `Code.ensure_loaded?/1`.

The `WebSearchBatch` in `batch_actions.ex` calls `WebSearch.run` internally, so it gets browser behavior automatically with no changes.

---

### 5. Update tests

**Depends on:** Changes 1-4

**Remove:** `test/examples/studio_pipeline_test.exs`
- Tests `Pipeline.run/2`, `build_stages`, `article`, `trace_provenance` — all being removed or moved

**Remove:** `test/examples/studio_live_test.exs`
- Tests `Pipeline.run_live/2` — being removed

**Rewrite:** `test/examples/studio_strategy_test.exs` → rename to `studio_agent_test.exs`

```elixir
defmodule JidoRunicTest.Examples.StudioAgentTest do
  use ExUnit.Case

  alias JidoRunic.Examples.Studio.OrchestratorAgent
  alias JidoRunic.Examples.Studio.Pipeline

  setup do
    Application.put_env(:jido_runic, :studio_mock_mode, true)
    test_id = System.unique_integer([:positive])
    jido_name = :"jido_studio_test_#{test_id}"
    {:ok, _pid} = Jido.start_link(name: jido_name)
    on_exit(fn -> Application.delete_env(:jido_runic, :studio_mock_mode) end)
    %{jido: jido_name}
  end

  describe "build_strategy_workflow/0" do
    test "creates a valid chained workflow" do
      workflow = Pipeline.build_strategy_workflow()
      assert is_struct(workflow, Runic.Workflow)
      assert Runic.Workflow.get_component(workflow, :plan_queries) != nil
      assert Runic.Workflow.get_component(workflow, :web_search_batch) != nil
      assert Runic.Workflow.get_component(workflow, :extract_claims_batch) != nil
      assert Runic.Workflow.get_component(workflow, :build_outline) != nil
      assert Runic.Workflow.get_component(workflow, :draft_sections_batch) != nil
      assert Runic.Workflow.get_component(workflow, :edit_and_assemble) != nil
    end
  end

  describe "OrchestratorAgent.run/2" do
    test "produces results in mock mode", %{jido: jido} do
      result = OrchestratorAgent.run("Elixir Concurrency", mock: true, jido: jido)
      assert result.topic == "Elixir Concurrency"
      assert result.status == :completed
      assert length(result.productions) > 0
      assert length(result.facts) > 0
    end

    test "produces an article-like production", %{jido: jido} do
      result = OrchestratorAgent.run("Elixir Concurrency", mock: true, jido: jido)
      assert Enum.any?(result.productions, &match?(%{markdown: _}, &1))
    end

    test "includes debug events", %{jido: jido} do
      result = OrchestratorAgent.run("Elixir Concurrency", mock: true, jido: jido)
      assert is_list(result.events)
      assert length(result.events) > 0
    end
  end
end
```

---

## Execution Order

```
Step 1: strategy.ex (top-level status)  ─┐
Step 4: actions.ex (browser WebSearch)   ─┤── parallel, independent
                                          │
Step 2: orchestrator_agent.ex (run/2)   ──┤── depends on step 1
                                          │
Step 3: pipeline.ex (strip down)        ──┤── depends on step 2
Step 5: tests (rewrite/remove)          ──┘── depends on steps 1-4
```

## What stays unchanged

| File | Why |
|------|-----|
| `strategy.ex` core logic | signal routing, cmd/2, dispatch_runnables, tick, action_specs — all correct |
| `execute_runnable_exec.ex` | DirectiveExec for async runnable dispatch — just built, works |
| `execute_runnable.ex` | Directive struct definition |
| `batch_actions.ex` | Fan-out adapters for linear DAG — still needed |
| `fixtures.ex` | Mock data for deterministic tests |
| `schemas.ex` | Struct definitions used by fixtures |
| All other actions | PlanQueries, ExtractClaims, BuildOutline, DraftSection, EditAndAssemble |

## Success Criteria

- [ ] `OrchestratorAgent.run("topic", mock: true)` returns productions + facts + events
- [ ] No `Pipeline.run*` functions remain — agent owns execution
- [ ] `await_completion` works (no polling) because strategy sets `agent.state.status`
- [ ] Debug events are captured and returned via `recent_events`
- [ ] WebSearch uses `jido_browser` in live mode when available, clear error when not
- [ ] Mock mode still works identically for CI — deterministic fixtures
- [ ] All tests pass via `mix test` in `projects/jido_runic`
