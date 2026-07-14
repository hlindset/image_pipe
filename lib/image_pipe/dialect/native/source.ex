defmodule ImagePipe.Dialect.Native.Source do
  @moduledoc """
  Decoded native source string → `ImagePipe.Plan.Source` translation
  [native §Sources: "Both forms feed the core source-resolution toolkit
  (relative path → configured source; scheme forms per host config) —
  never another dialect's translation code"].

  `translate/2` consumes the already-decoded source string produced by
  `ImagePipe.Dialect.Native.Path.extract/1` (percent-decoded once for a
  `src` tail, base64url-decoded for a `src64` tail) and classifies it:

    * no `scheme://` prefix — a root-relative `%Plan.Source.Path{}`. The
      decoded string is the source of truth: it is split into segments on
      `/` with no further decoding.
    * `http://` or `https://` — an absolute `%Plan.Source.URL{}`.
    * anything else (another scheme, an empty source, or a malformed
      authority) — `{:error, {:invalid_source, reason}}`.

  Scheme forms routed through host config (an imgproxy-`source_schemes`-
  style escape hatch) are out of scope here — this is probe scope, covering
  only the relative-path and http(s) forms. `config` is accepted for
  interface symmetry with that eventual routing but is currently unused.

  `ImagePipe.Source.resolve/3` consumes the returned `Plan.Source.t()`
  unchanged.
  """

  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.URL

  @schemes %{"http" => :http, "https" => :https}
  @scheme_prefix ~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\//

  @spec translate(String.t(), keyword()) ::
          {:ok, ImagePipe.Plan.Source.t()} | {:error, {:invalid_source, term()}}
  def translate("", _config), do: {:error, {:invalid_source, :empty_source}}

  def translate(source, config) when is_binary(source) do
    case Regex.run(@scheme_prefix, source) do
      [_match, scheme] -> url_translate(String.downcase(scheme), source, config)
      nil -> {:ok, path_translate(source)}
    end
  end

  defp path_translate(source) do
    %Path{segments: String.split(source, "/")}
  end

  defp url_translate(scheme, source, _config) when is_map_key(@schemes, scheme) do
    build_url(Map.fetch!(@schemes, scheme), URI.parse(source))
  end

  defp url_translate(scheme, _source, _config) do
    {:error, {:invalid_source, {:unsupported_scheme, scheme}}}
  end

  defp build_url(_scheme, %URI{host: host}) when host in [nil, ""] do
    {:error, {:invalid_source, :missing_host}}
  end

  defp build_url(_scheme, %URI{userinfo: userinfo}) when is_binary(userinfo) do
    {:error, {:invalid_source, :userinfo_not_allowed}}
  end

  defp build_url(_scheme, %URI{fragment: fragment}) when is_binary(fragment) do
    {:error, {:invalid_source, :fragment_not_allowed}}
  end

  defp build_url(scheme, %URI{} = uri) do
    {:ok,
     %URL{
       scheme: scheme,
       host: String.downcase(uri.host),
       port: uri.port,
       path: url_path_segments(uri.path),
       query: uri.query
     }}
  end

  defp url_path_segments(nil), do: []
  defp url_path_segments("/"), do: []
  defp url_path_segments(path), do: path |> String.trim_leading("/") |> String.split("/")
end
