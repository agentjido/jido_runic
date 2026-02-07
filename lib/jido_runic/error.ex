defmodule JidoRunic.Error do
  @moduledoc """
  Centralized error handling for JidoRunic using Splode.

  Error classes are for classification; concrete `...Error` structs are for raising/matching.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  defmodule Invalid do
    @moduledoc "Invalid input error class for Splode."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Execution error class for Splode."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Splode."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      defexception [:message, :details]
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Error for invalid input parameters."
    defexception [:message, :field, :value, :details]
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for runtime execution failures."
    defexception [:message, :details]
  end

  defmodule ConfigError do
    @moduledoc "Error for invalid or missing configuration."
    defexception [:message, :key, :details]
  end

  @spec validation_error(String.t(), map()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) do
    InvalidInputError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end

  @spec execution_error(String.t(), map()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(message: message, details: details)
  end

  @spec config_error(String.t(), map()) :: ConfigError.t()
  def config_error(message, details \\ %{}) do
    ConfigError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end
end
