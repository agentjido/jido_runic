defmodule JidoRunic.Examples.Studio.OrchestratorAgent do
  @moduledoc "Orchestrator agent for the AI Research Studio, powered by JidoRunic.Strategy."
  use Jido.Agent,
    name: "studio_orchestrator",
    strategy: JidoRunic.Strategy,
    schema: []
end
