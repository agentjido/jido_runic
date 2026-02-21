# JidoRunic

[![Hex.pm](https://img.shields.io/hexpm/v/jido_runic.svg)](https://hex.pm/packages/jido_runic)
[![Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/jido_runic)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Bridge between [Runic's](https://github.com/zblanco/runic) DAG-based workflow engine and [Jido's](https://github.com/agentjido/jido) signal-driven agent framework.

## Features

- **ActionNode** — wrap any Jido Action as a Runic workflow node with automatic input/output derivation
- **Signal ↔ Fact** — bidirectional adapter preserving provenance across both systems
- **Signal-gated workflows** — gate DAG execution on Jido signal type patterns
- **Strategy integration** — plug a Runic DAG directly into Jido's agent strategy loop
- **Runnable dispatch** — directives for scheduling Runic runnables through the Jido runtime
- **Provenance tracking** — trace fact ancestry chains and generate execution summaries

## Installation

Add `jido_runic` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_runic, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
defmodule MyApp.Greet do
  use Jido.Action,
    name: "greet",
    schema: [name: [type: :string, required: true]]

  def run(params, _context) do
    {:ok, %{greeting: "Hello, #{params.name}!"}}
  end
end

# Wrap the action as a workflow node
node = JidoRunic.ActionNode.new(MyApp.Greet, %{}, name: :greet)

# Build a single-step workflow and run it
alias Runic.Workflow

workflow =
  Workflow.new(:hello)
  |> Workflow.add(node)

result = Workflow.react_until_satisfied(workflow, %{name: "World"})
Workflow.raw_productions(result)
# => [%{greeting: "Hello, World!"}]
```

## Core Concepts

### `JidoRunic.ActionNode`

Wraps a Jido Action module as a Runic workflow node. The action's schema is introspected to derive inputs; execution delegates to `Jido.Exec.run/2`. Implements Runic's `Invokable`, `Component`, and `Transmutable` protocols.

```elixir
node = JidoRunic.ActionNode.new(MyApp.SomeAction, %{static: "param"}, name: :my_step)
```

### `JidoRunic.SignalFact`

Bidirectional adapter between Jido Signals and Runic Facts. Maps Jido's causality tracking (`signal.source`, `signal.jidocause`) to Runic's fact ancestry chain.

```elixir
fact = JidoRunic.SignalFact.from_signal(signal)
signal = JidoRunic.SignalFact.to_signal(fact, type: "my.event", source: "/my/source")
```

### `JidoRunic.SignalMatch`

A Runic match node that gates downstream execution based on Jido signal type prefix patterns. Only facts whose `:type` field matches the pattern pass through.

```elixir
gate = JidoRunic.SignalMatch.new("user.created")

workflow =
  Workflow.new(:gated)
  |> Workflow.add(gate)
  |> Workflow.add(action_node, to: gate)
```

### `JidoRunic.Strategy`

A `Jido.Agent.Strategy` implementation powered by a Runic DAG. Incoming signals are converted to facts and fed into the workflow. Runnables are emitted as `ExecuteRunnable` directives. Completed runnables are applied back, advancing the workflow until satisfied.

**Operational notes**

- `execution_mode: :auto | :step` (default `:auto`). Step mode holds runnables until you send `runic.step` or `runic.resume`, useful for UI-driven debugging and demos.
- Action nodes default to `timeout: 0` (inline) so Runic owns concurrency/time budgeting; override per node if you want Task-based timeouts.
- To delegate work, set `executor: {:child, tag}` on an ActionNode and configure `child_modules: %{tag => MyChildAgent}` in strategy opts. Missing child modules emit a `runic.child.missing` signal for observability.

### `JidoRunic.Directive.ExecuteRunnable`

A Jido directive that schedules execution of a Runic `Runnable`. The runtime interprets this by running the runnable and sending the result back as a completion signal.

### `JidoRunic.Introspection`

Provenance queries and execution summaries. Walk fact ancestry chains or generate statistics about a workflow's execution state.

```elixir
{:ok, chain} = JidoRunic.Introspection.provenance_chain(workflow, fact_hash)
summary = JidoRunic.Introspection.execution_summary(workflow)
# => %{total_nodes: 3, facts_produced: 5, satisfied: true, productions: 1}
```

## Strategy-Driven Workflows

Use `JidoRunic.Strategy` to drive a Runic DAG through Jido's agent loop:

```elixir
defmodule MyApp.WorkflowAgent do
  use Jido.Agent,
    name: "workflow_agent",
    strategy: JidoRunic.Strategy,
    schema: []
end

# Build a multi-step DAG
plan = JidoRunic.ActionNode.new(MyApp.PlanAction, %{}, name: :plan)
execute = JidoRunic.ActionNode.new(MyApp.ExecuteAction, %{}, name: :execute)

workflow =
  Runic.Workflow.new(:pipeline)
  |> Runic.Workflow.add(plan)
  |> Runic.Workflow.add(execute, to: :plan)

# Initialize the agent and set the workflow
agent = MyApp.WorkflowAgent.new()
ctx = %{strategy_opts: []}

{agent, []} = JidoRunic.Strategy.cmd(agent,
  [%Jido.Instruction{action: :runic_set_workflow, params: %{workflow: workflow}}], ctx)

# Feed input — returns ExecuteRunnable directives
{agent, directives} = JidoRunic.Strategy.cmd(agent,
  [%Jido.Instruction{action: :runic_feed_signal, params: %{data: %{topic: "Elixir"}}}], ctx)

# Execute runnables and apply results until satisfied
Enum.reduce(directives, agent, fn %JidoRunic.Directive.ExecuteRunnable{} = d, agent ->
  runnable = JidoRunic.Strategy.execute_runnable(d)
  {agent, _dirs} = JidoRunic.Strategy.cmd(agent,
    [%Jido.Instruction{action: :runic_apply_result, params: %{runnable: runnable}}], ctx)
  agent
end)
```

## AI Research Studio Example

The `lib/examples/studio/` directory contains a full showcase: a six-stage research pipeline (plan → search → extract → outline → draft → edit) built entirely with ActionNodes and Runic workflows.

```bash
# Run with mock fixtures
cd projects/jido_runic && mix run lib/examples/studio_demo.exs

# Run with live LLM calls (requires ANTHROPIC_API_KEY in .env)
STUDIO_LIVE=1 mix run lib/examples/studio_demo.exs
```

## Architecture

```
Jido Signal  ──→  SignalFact.from_signal/1  ──→  Runic Fact
Runic Fact   ──→  SignalFact.to_signal/2    ──→  Jido Signal
Jido Action  ──→  ActionNode.new/3          ──→  Runic Workflow Node

┌─────────────────────────────────────────────────────────────┐
│                    JidoRunic.Strategy                        │
│                                                             │
│  Signal in ──→ SignalFact.from_signal ──→ Workflow.plan_eagerly
│                                                │            │
│                                       prepare_for_dispatch  │
│                                                │            │
│                                      ExecuteRunnable dirs   │
│                                                │            │
│  Runtime executes runnable ──→ Workflow.apply_runnable       │
│                                                │            │
│                              ┌── more runnables? ──→ loop   │
│                              └── satisfied? ──→ Emit results │
└─────────────────────────────────────────────────────────────┘
```

## License

Apache License 2.0 — See [LICENSE](LICENSE) for details.

## Package Purpose

`jido_runic` provides workflow graph planning/execution utilities used by higher-level Jido agents and orchestration packages.

## Testing Paths

- Unit/workflow tests: `mix test`
- Full quality gate: `mix quality`
- Coverage run: `mix test --cover`
