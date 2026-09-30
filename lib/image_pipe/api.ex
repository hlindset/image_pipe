defmodule ImagePipe.API do
  @moduledoc """
  ImagePipe's URL grammar: lexing, parsing, presets, canonical serialization,
  and URL generation. `ImagePipe.Plug` verifies, parses, and serves requests
  through this module set.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Format, ImagePipe.Plan, ImagePipe.Security, ImagePipe.Source],
    exports: [Diagnostic, DiagnosticRenderer, Parser, Path]

  alias ImagePipe.Security

  @doc false
  defdelegate compile_presets(presets), to: ImagePipe.API.Presets, as: :validate_config

  @doc false
  defdelegate url(plan, source, config, options), to: ImagePipe.API.URL, as: :build

  @doc false
  defdelegate sign_path(path, config), to: ImagePipe.API.URL

  @doc """
  Encrypts a UTF-8 source using a validated mount configuration.

  The returned value is the token only. The host places it after the `enc/`
  source marker and signs the complete request path.

  `:iv` overrides the configured `:iv_mode` with `:deterministic`, `:random`,
  or an explicit 16-byte binary. Explicit IVs must be unpredictable or
  secret-keyed over the complete source and never reused for different sources
  under the same key. Prefer `ImagePipe.url/3` to generate a complete signed URL.
  """
  @spec encrypt_source(term(), keyword(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def encrypt_source(source, config, options \\ []) do
    Security.encrypt_source(source, config, options)
  end
end
