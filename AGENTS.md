# JidoRunic Agent Development Guide

## Commands
- **Compile**: `mix compile`
- **Test all**: `mix test`
- **Test single file**: `mix test test/path/to/test_file.exs`
- **Test with coverage**: `mix coveralls.html`
- **Quality check**: `mix quality` (format, compile, credo, dialyzer, doctor)
- **Format code**: `mix format`
- **Type check**: `mix dialyzer`
- **Lint**: `mix credo`

## Code Style
- Elixir `~> 1.18` baseline
- Use `snake_case` for functions/variables, `PascalCase` for modules
- Add `@moduledoc` and `@doc` to all public functions
- Use `@spec` for type specifications
- Return tagged tuples: `{:ok, result}` or `{:error, reason}`
- Use Zoi schemas for struct validation
- Use Splode for error handling via `JidoRunic.Error`
- Prefix test modules with namespace: `JidoRunicTest.ModuleName`

## Architecture
- `JidoRunic` - Main module, public API
- `JidoRunic.Error` - Centralized Splode error handling

## Git Commit Guidelines
- Use conventional commit format: `type(scope): description`
- Types: feat, fix, docs, style, refactor, test, chore, ci
