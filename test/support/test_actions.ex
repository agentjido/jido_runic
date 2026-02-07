defmodule JidoRunicTest.TestActions do
  @moduledoc false

  defmodule AddOne do
    @moduledoc false
    use Jido.Action,
      name: "add_one",
      description: "Adds one to a value",
      schema: [
        value: [type: :integer, required: true]
      ]

    def run(%{value: value}, _context) do
      {:ok, %{value: value + 1}}
    end
  end

  defmodule Double do
    @moduledoc false
    use Jido.Action,
      name: "double",
      description: "Doubles a value",
      schema: [
        value: [type: :integer, required: true]
      ]

    def run(%{value: value}, _context) do
      {:ok, %{value: value * 2}}
    end
  end

  defmodule Concat do
    @moduledoc false
    use Jido.Action,
      name: "concat",
      description: "Concatenates strings",
      schema: [
        a: [type: :string, required: true],
        b: [type: :string, required: true]
      ]

    def run(%{a: a, b: b}, _context) do
      {:ok, %{result: a <> b}}
    end
  end

  defmodule FailingAction do
    @moduledoc false
    use Jido.Action,
      name: "failing_action",
      description: "Always fails",
      schema: []

    def run(_params, _context) do
      {:error, "intentional failure"}
    end
  end

  defmodule NoSchemaAction do
    @moduledoc false
    use Jido.Action,
      name: "no_schema",
      description: "Action without schema"

    def run(params, _context) do
      {:ok, params}
    end
  end
end
