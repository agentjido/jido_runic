defmodule JidoRunicTest.TestAgents do
  @moduledoc false

  defmodule SimpleAgent do
    @moduledoc false
    use Jido.Agent,
      name: "simple_agent",
      strategy: JidoRunic.Strategy,
      schema: []
  end
end
