defmodule JidoRunicTest.Examples.StudioStrategyTest do
  use ExUnit.Case

  alias JidoRunic.Examples.Studio.Pipeline

  setup do
    Application.put_env(:jido_runic, :studio_mock_mode, true)
    on_exit(fn -> Application.delete_env(:jido_runic, :studio_mock_mode) end)
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

  describe "run_strategy/2" do
    test "produces results in mock mode" do
      result = Pipeline.run_strategy("Elixir Concurrency", mock: true)

      assert result.topic == "Elixir Concurrency"
      assert result.mock_mode == true
      assert is_list(result.productions)
      assert length(result.productions) > 0
      assert is_list(result.facts)
      assert length(result.facts) > 0
    end

    test "produces an article-like production" do
      result = Pipeline.run_strategy("Elixir Concurrency", mock: true)

      has_markdown =
        Enum.any?(result.productions, fn p ->
          is_map(p) and Map.has_key?(p, :markdown)
        end)

      assert has_markdown
    end

    test "facts have ancestry for provenance" do
      result = Pipeline.run_strategy("Elixir Concurrency", mock: true)

      facts_with_ancestry =
        Enum.filter(result.facts, fn f ->
          f.ancestry != nil
        end)

      assert length(facts_with_ancestry) > 0
    end

    test "reaches satisfied status" do
      result = Pipeline.run_strategy("Elixir Concurrency", mock: true)
      assert result.status == :satisfied
    end
  end
end
