# Contributing to JidoRunic

## Getting Started

1. Clone the repository
2. Run `mix setup` to install dependencies and git hooks
3. Run `mix test` to verify everything works

## Development Workflow

1. Create a feature branch from `main`
2. Make your changes
3. Run `mix quality` to verify code quality
4. Run `mix test` to run the test suite
5. Submit a pull request

## Quality Standards

All PRs must pass:
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix credo --min-priority higher`
- `mix dialyzer`
- `mix doctor --raise`
- `mix test`

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(workflow): add step composition support
fix(error): handle nil input gracefully
docs: update README with usage examples
```
