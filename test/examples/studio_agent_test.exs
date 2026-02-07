defmodule JidoRunicTest.Examples.StudioAgentTest do
  use ExUnit.Case

  alias JidoRunic.Examples.Studio.OrchestratorAgent

  describe "build_workflow/0" do
    test "creates a valid chained workflow" do
      workflow = OrchestratorAgent.build_workflow()
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
    setup do
      test_id = System.unique_integer([:positive])
      jido_name = :"jido_studio_test_#{test_id}"
      {:ok, _pid} = Jido.start_link(name: jido_name)
      %{jido: jido_name}
    end

    @tag :live
    test "produces results", %{jido: jido} do
      result = OrchestratorAgent.run("Elixir Concurrency", jido: jido, timeout: 60_000)

      assert result.topic == "Elixir Concurrency"
      assert result.status == :completed
      assert is_list(result.productions)
      assert length(result.productions) > 0
      assert is_list(result.facts)
      assert length(result.facts) > 0
    end

    @tag :live
    test "produces an article-like production", %{jido: jido} do
      result = OrchestratorAgent.run("Elixir Concurrency", jido: jido, timeout: 60_000)
      assert Enum.any?(result.productions, &match?(%{markdown: _}, &1))
    end

    @tag :live
    test "includes debug events", %{jido: jido} do
      result = OrchestratorAgent.run("Elixir Concurrency", jido: jido, timeout: 60_000)
      assert is_list(result.events)
      assert length(result.events) > 0
    end
  end
end
