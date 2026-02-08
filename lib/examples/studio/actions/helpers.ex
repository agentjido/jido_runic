defmodule Jido.Runic.Examples.Studio.Actions.Helpers do
  @moduledoc false

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

  def generate_object(prompt, schema, opts \\ []) do
    model = Jido.AI.resolve_model(:fast)
    messages = [%{role: "user", content: prompt}]
    default_opts = [max_tokens: 1024, temperature: 0.7]
    opts = Keyword.merge(default_opts, opts)

    case ReqLLM.Generation.generate_object(model, messages, schema, opts) do
      {:ok, response} ->
        {:ok, ReqLLM.Response.object(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
