defmodule Jido.Runic.Examples.Branching.Actions.FalseBranch do
  @moduledoc """
  Produce branch output when the structured decision is false.
  """

  use Jido.Action,
    name: "branching_false_branch",
    description: "Runs when the LLM decision is false",
    schema: [
      question: [type: :string, required: true],
      is_true: [type: :boolean, required: true],
      confidence: [type: :float, required: true],
      reasoning: [type: :string, required: true]
    ]

  @impl true
  def run(%{question: question, is_true: false, confidence: confidence, reasoning: reasoning}, _context) do
    {:ok,
     %{
       branch: :false_path,
       branch_result: "FALSE path selected for \"#{question}\" (confidence=#{format(confidence)}).",
       explanation: reasoning
     }}
  end

  def run(%{is_true: true}, _context) do
    {:error, {:invalid_branch_input, :expected_false}}
  end

  defp format(value), do: :erlang.float_to_binary(value, decimals: 2)
end
