defmodule Jido.RunicTest.Actions.Add do
  @moduledoc false
  use Jido.Action,
    name: "add",
    description: "Adds a value to the input",
    schema: [
      value: [type: :integer, required: true, doc: "The value to add"],
      amount: [type: :integer, default: 1, doc: "Amount to add"]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{value: params.value + params.amount}}
  end
end

defmodule Jido.RunicTest.Actions.Double do
  @moduledoc false
  use Jido.Action,
    name: "double",
    description: "Doubles the input value",
    schema: [
      value: [type: :integer, required: true, doc: "The value to double"]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{value: params.value * 2}}
  end
end

defmodule Jido.RunicTest.Actions.Fail do
  @moduledoc false
  use Jido.Action,
    name: "fail",
    description: "Always fails",
    schema: [
      reason: [type: :string, default: "intentional failure", doc: "Failure reason"]
    ]

  @impl true
  def run(params, _context) do
    {:error, params.reason}
  end
end

defmodule Jido.RunicTest.Actions.NoSchema do
  @moduledoc false
  use Jido.Action,
    name: "no_schema",
    description: "Action with no schema"

  @impl true
  def run(params, _context) do
    {:ok, params}
  end
end
