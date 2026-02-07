# JidoRunic Usage Rules

## Overview

JidoRunic integrates Runic DAG workflow composition with the Jido agent ecosystem.

## Dependencies

- Requires Elixir `~> 1.18`
- Depends on `jido` and `runic`

## Patterns

### Error Handling

Use `JidoRunic.Error` for all error types:

```elixir
{:error, JidoRunic.Error.validation_error("invalid input", %{field: :name})}
{:error, JidoRunic.Error.execution_error("workflow failed", %{step: :transform})}
```

### Return Values

All public functions return tagged tuples:

```elixir
{:ok, result}
{:error, reason}
```
