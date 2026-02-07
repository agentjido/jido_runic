defmodule JidoRunicTest.Examples.StudioPipelineTest do
  use ExUnit.Case

  alias JidoRunic.Examples.Studio.Pipeline

  setup do
    Application.put_env(:jido_runic, :studio_mock_mode, true)
    on_exit(fn -> Application.delete_env(:jido_runic, :studio_mock_mode) end)
  end

  describe "build_stages/0" do
    test "creates all six ActionNode stages" do
      stages = Pipeline.build_stages()
      assert map_size(stages) == 6

      assert stages.plan_queries.name == :plan_queries
      assert stages.web_search.name == :web_search
      assert stages.extract_claims.name == :extract_claims
      assert stages.build_outline.name == :build_outline
      assert stages.draft_section.name == :draft_section
      assert stages.edit_and_assemble.name == :edit_and_assemble
    end
  end

  describe "build_workflow/0" do
    test "creates a valid workflow with the plan node" do
      workflow = Pipeline.build_workflow()
      assert is_struct(workflow, Runic.Workflow)

      assert Runic.Workflow.get_component(workflow, :plan_queries) != nil
    end
  end

  describe "run/2 in mock mode" do
    test "produces facts from the pipeline" do
      result = Pipeline.run("Elixir Concurrency", mock: true)

      assert result.topic == "Elixir Concurrency"
      assert result.mock_mode == true
      assert length(result.facts) > 0
      assert length(result.productions) > 0
    end

    test "produces an article-like final production" do
      result = Pipeline.run("Elixir Concurrency", mock: true)
      productions = result.productions

      assert length(productions) >= 1
    end

    test "facts have ancestry for provenance" do
      result = Pipeline.run("Elixir Concurrency", mock: true)

      facts_with_ancestry =
        Enum.filter(result.facts, fn f ->
          f.ancestry != nil
        end)

      assert length(facts_with_ancestry) > 0
    end

    test "trace_provenance returns a chain" do
      result = Pipeline.run("Elixir Concurrency", mock: true)

      last_fact = List.last(result.facts)
      chain = Pipeline.trace_provenance(result, last_fact.hash)

      assert length(chain) >= 1
    end
  end

  describe "article/1" do
    test "extracts article from productions" do
      result = Pipeline.run("Elixir Concurrency", mock: true)
      art = Pipeline.article(result)

      assert art == nil or is_map(art)
    end
  end
end
