defmodule ImagePipe.API do
  @moduledoc """
  ImagePipe's URL API, mounted through `plug ImagePipe.Plug,
  sources: [...]`. Owns parsing (verify → lex → parse), configuration,
  and error rendering. Shared processing owns expiry/output preflight, and
  the source boundary translates source strings.
  `ImagePipe.Plug` orchestrates the request lifecycle.

  ## Mount prefix caveat

  `ImagePipe.API.Path` strips `conn.script_name` from `conn.request_path`
  as a raw prefix. Because Plug decodes `script_name`, mount paths must use
  canonical unescaped ASCII. A segment that changes when percent-encoded
  raises at request time as host misconfiguration (500-class).
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Processing,
      ImagePipe.Response,
      ImagePipe.Security,
      ImagePipe.Source
    ],
    exports: []

  alias ImagePipe.API.Errors
  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan.Request
  alias ImagePipe.Processing
  alias ImagePipe.Security
  alias ImagePipe.Source.Parser, as: APISource

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

  def parse(%Plug.Conn{} = conn, config) do
    {sig, signed_path} = Path.split_signature(conn)

    result =
      with {:ok, key_index} <- Security.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(conn) |> normalize_lex_error(),
           {:ok, lexed} <- decrypt_source(lexed, config),
           {:ok, request} <- Parser.parse(lexed, config) do
        {_marker, source, _span} = lexed.source
        {request, source, key_index}
      end

    case result do
      {%Request{} = request, source, key_index} ->
        {{:ok, request, source}, %{result: :ok, sig_key_index: key_index}}

      {:error, _reason} = error ->
        # Deliberately NO error tag — preserving the chain's parse stop shape.
        {error, %{result: :error}}
    end
  end

  def prepare(%Request{} = request, source, config, accept_header) do
    with {:ok, policy} <- Processing.prepare(request, config, accept_header),
         {:ok, plan_source} <- APISource.translate(source, config) do
      {:ok, plan_source, policy}
    end
  end

  def render_error(conn, reason), do: Errors.send(conn, reason)

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  defp decrypt_source(%{source: {:enc, token, span}} = lexed, config) do
    case Security.decrypt_source(token, config) do
      {:ok, source} -> {:ok, %{lexed | source: {:enc, source, span}}}
      {:error, :invalid_concealed_source} = error -> error
    end
  end

  defp decrypt_source(lexed, _config), do: {:ok, lexed}
end
