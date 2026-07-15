defmodule ImagePipe.Dialect.Imgproxy.SourceScheme do
  @moduledoc """
  Parser extension for custom imgproxy source schemes.
  """

  @callback translate(source :: String.t(), opts :: keyword()) ::
              {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}
end
