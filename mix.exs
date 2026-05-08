defmodule JidoRunic.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_runic"
  @description "Runic workflow integration for the Jido ecosystem"

  def project do
    [
      app: :jido_runic,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Documentation
      name: "Jido.Runic",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Test Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        export: "cov",
        ignore_modules: [~r/^Jido\.RunicTest\./, ~r/^Jido\.Runic\.Examples\./]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "examples"]
  defp elixirc_paths(:test), do: ["lib", "examples", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Jido ecosystem
      {:jido, "~> 2.1"},
      {:jido_ai, "~> 2.1.0", only: [:dev, :test]},

      # Runic - DAG workflow composition
      {:runic, "~> 0.1.0-alpha.4"},
      {:multigraph, "~> 0.16.1-mg.1"},

      # Runtime deps
      {:zoi, "~> 0.16"},

      # Dev/Test
      {:credo, "~> 1.7.17", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:dotenv, "~> 3.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: "test --exclude flaky",
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "examples", "mix.exs", "README.md", "CONTRIBUTING.md", "LICENSE"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/jido_runic",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CONTRIBUTING.md"
      ]
    ]
  end
end
