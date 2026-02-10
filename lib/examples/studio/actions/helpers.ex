defmodule Jido.Runic.Examples.Studio.Actions.Helpers do
  @moduledoc """
  Thin wrappers over ReqLLM helpers used by studio actions to keep examples tidy.
  """

  @doc """
  Generate free-form text from the fast model.

  Accepts a `prompt` string and optional overrides for generation opts
  (`:max_tokens`, `:temperature`, etc). Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec llm_call(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def llm_call(prompt, opts \\ []) do
    model = Jido.AI.resolve_model(:fast)
    messages = [%{role: "user", content: prompt}]
    default_opts = [max_tokens: 2048, temperature: 0.7]
    opts = Keyword.merge(default_opts, opts)

    case ReqLLM.Generation.generate_text(model, messages, opts) do
      {:ok, response} ->
        {:ok, ReqLLM.Response.text(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a structured object adhering to `schema`.

  Accepts a string `prompt`, a schema map expected by ReqLLM, and optional
  generation overrides. Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec generate_object(String.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate_object(prompt, schema, opts \\ []) do
    model = Jido.AI.resolve_model(:fast)
    messages = [%{role: "user", content: prompt}]
    default_opts = [max_tokens: 1024, temperature: 0.7]
    opts = Keyword.merge(default_opts, opts)
    schema = if Keyword.keyword?(schema), do: Map.new(schema), else: schema

    case ReqLLM.Generation.generate_object(model, messages, schema, opts) do
      {:ok, response} ->
        {:ok, ReqLLM.Response.object(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
