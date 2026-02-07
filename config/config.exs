import Config

if Code.ensure_loaded?(DotenvParser) do
  env_file = Path.join(File.cwd!(), ".env")

  if File.exists?(env_file) do
    for {key, value} <- DotenvParser.load_file(env_file) do
      System.put_env(key, value)
    end
  end
end

config :jido_ai,
  model_aliases: %{
    fast: "anthropic:claude-haiku-4-5",
    capable: "anthropic:claude-sonnet-4-20250514"
  }

import_config "#{config_env()}.exs"
