defmodule ImagePipe.Native.SourceScheme do
  @moduledoc """
  Host extension point for translating custom source schemes.

  Configure a translator under the lowercase scheme name:

      source_schemes: %{"asset" => {MyApp.AssetSource, adapter: :assets}}

  The callback receives the decoded source string and the configured keyword
  options. It returns one of the concrete `ImagePipe.Plan.Source` structs for
  the shared source resolver:

      defmodule MyApp.AssetSource do
        @behaviour ImagePipe.Native.SourceScheme

        alias ImagePipe.Plan.Source.Reference

        @impl true
        def translate("asset://" <> id, opts) do
          {:ok, %Reference{adapter: Keyword.fetch!(opts, :adapter), id: id}}
        end
      end

  Callback failures are exposed to clients as a fixed invalid-source response;
  their reason is not included in the response or telemetry.
  """

  @callback translate(source :: String.t(), opts :: keyword()) ::
              {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}
end
