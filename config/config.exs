import Config

config :jido_ai,
  model_aliases: %{
    fast: "anthropic:claude-haiku-4-5",
    capable: "anthropic:claude-sonnet-4-20250514"
  }

if config_env() == :dev do
  config :git_ops,
    mix_project: JidoRunic.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/jido_runic",
    manage_mix_version?: true,
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      deps: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end

import_config "#{config_env()}.exs"
