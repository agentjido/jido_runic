defmodule Jido.Runic.Examples.Branching.Actions.TrueBranch do
  @moduledoc """
  Produce branch output when the structured decision is true.
  """

  use Jido.Action,
    name: "branching_true_branch",
    description: "Runs when the LLM decision is true",
    schema: [
      question: [type: :string, required: true],
      is_true: [type: :boolean, required: true],
      confidence: [type: :float, required: true],
      reasoning: [type: :string, required: true]
    ]

  @impl true
  def run(%{question: question, is_true: true, confidence: confidence, reasoning: reasoning}, _context) do
    {:ok,
     %{
       branch: :true_path,
       branch_result: "TRUE path selected for \"#{question}\" (confidence=#{format(confidence)}).",
       explanation: reasoning
     }}
  end

  def run(%{is_true: false}, _context) do
    {:error, {:invalid_branch_input, :expected_true}}
  end

  defp format(value), do: :erlang.float_to_binary(value, decimals: 2)
end
