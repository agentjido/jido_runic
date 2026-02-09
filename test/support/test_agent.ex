defmodule Jido.RunicTest.TestAgent do
  @moduledoc false
  use Jido.Agent,
    name: "runic_test_agent",
    description: "Test agent for Runic strategy tests",
    strategy: Jido.Runic.Strategy,
    schema: [
      value: [type: :any, default: nil]
    ]
end

defmodule Jido.RunicTest.TestAgentWithWorkflow do
  @moduledoc false

  alias Jido.Runic.ActionNode
  alias Jido.RunicTest.Actions.Add

  use Jido.Agent,
    name: "runic_test_agent_wf",
    description: "Test agent with a single-node workflow",
    strategy: {Jido.Runic.Strategy, workflow_fn: &__MODULE__.build_workflow/0},
    schema: [
      value: [type: :any, default: nil]
    ]

  def build_workflow do
    Runic.Workflow.new(name: :single)
    |> Runic.Workflow.add(ActionNode.new(Add, %{amount: 10}, name: :add))
  end
end
