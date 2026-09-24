defmodule ImagePipe.Source.Parser do
  @moduledoc """
  Translates a decoded source string into `ImagePipe.Plan.Source`.

  `translate/2` consumes a source string, with any outer transport encoding
  already decoded, and classifies it:

    * no `scheme://` prefix — a root-relative `%Plan.Source.Path{}`. The
      decoded string is split into segments on `/` with no further decoding.
      An optional leading slash is normalized for ordinary root-relative paths.
    * `http://` or `https://` — an absolute `%Plan.Source.URL{}`. Inner URL
      path escapes are decoded once here and re-encoded by the HTTP adapter.
    * `s3://` — an `%Plan.Source.Object{}` with the query carried as its
      immutable revision.
    * configured schemes — a host translator returning a concrete
      `Plan.Source` value.
    * anything else (an unknown scheme, an empty source, or a malformed
      authority) — `{:error, {:invalid_source, reason}}`.

  `ImagePipe.Source.resolve/3` consumes the returned `Plan.Source.t()`
  unchanged.
  """

  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.Reference
  alias ImagePipe.Plan.Source.URL

  @http_schemes %{"http" => :http, "https" => :https}
  @scheme_prefix ~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\//
  @malformed_percent ~r/%($|[^0-9A-Fa-f]|[0-9A-Fa-f]$|[0-9A-Fa-f][^0-9A-Fa-f])/

  @spec translate(String.t(), keyword()) ::
          {:ok, ImagePipe.Plan.Source.t()} | {:error, {:invalid_source, term()}}
  def translate(source, config) when is_binary(source),
    do: source |> normalize() |> do_translate(config)

  @doc false
  def normalize("//" <> _ = source), do: source

  def normalize("/" <> rest = source) do
    # Removing the slash must not turn a path into a different source kind.
    case Regex.match?(@scheme_prefix, rest) do
      true -> source
      false -> rest
    end
  end

  def normalize(source), do: source

  defp do_translate("", _config), do: {:error, {:invalid_source, :empty_source}}

  defp do_translate(source, config) do
    case Regex.run(@scheme_prefix, source) do
      [_match, scheme] -> url_translate(String.downcase(scheme), source, config)
      nil -> {:ok, path_translate(source)}
    end
  end

  defp path_translate(source) do
    %Path{segments: String.split(source, "/")}
  end

  defp url_translate(scheme, source, _config) when is_map_key(@http_schemes, scheme) do
    build_url(Map.fetch!(@http_schemes, scheme), source, URI.parse(source))
  end

  defp url_translate("s3", source, _config) do
    build_s3(source, URI.parse(source))
  end

  defp url_translate(scheme, source, config) do
    custom_source(scheme, source, Keyword.get(config, :source_schemes, %{}))
  end

  defp build_url(scheme, source, %URI{} = uri) do
    with :ok <- validate_uri_authority(uri),
         {:ok, port} <- source_port(source),
         {:ok, path} <- url_path_segments(uri.path),
         :ok <- validate_percent_encoding(uri.query) do
      {:ok,
       %URL{
         scheme: scheme,
         host: String.downcase(uri.host),
         port: port || uri.port,
         path: path,
         query: uri.query
       }}
    else
      {:error, reason} -> {:error, {:invalid_source, reason}}
    end
  end

  defp build_s3(source, %URI{} = uri) do
    with :ok <- validate_uri_authority(uri),
         :ok <- reject_object_port(source),
         {:ok, key} <- object_key(uri.path),
         {:ok, revision} <- decode_optional(uri.query) do
      {:ok,
       %Object{
         adapter: :s3,
         scope: uri.host,
         key: key,
         revision: revision
       }}
    else
      {:error, reason} -> {:error, {:invalid_source, reason}}
    end
  end

  defp validate_uri_authority(%URI{host: host}) when host in [nil, ""],
    do: {:error, :missing_host}

  defp validate_uri_authority(%URI{userinfo: userinfo}) when is_binary(userinfo),
    do: {:error, :userinfo_not_allowed}

  defp validate_uri_authority(%URI{fragment: fragment}) when is_binary(fragment),
    do: {:error, :fragment_not_allowed}

  defp validate_uri_authority(%URI{}), do: :ok

  defp object_key(path) when path in [nil, "/"], do: {:error, :missing_object_key}

  defp object_key(path) do
    path
    |> String.replace_prefix("/", "")
    |> percent_decode()
    |> case do
      {:ok, ""} -> {:error, :missing_object_key}
      result -> result
    end
  end

  defp custom_source(scheme, source, source_schemes) do
    case source_schemes do
      %{^scheme => {translator, translator_opts}} ->
        call_source_translator(scheme, source, translator, translator_opts)

      _source_schemes ->
        {:error, {:invalid_source, {:unsupported_scheme, scheme}}}
    end
  end

  defp call_source_translator(scheme, source, translator, translator_opts) do
    case translator.translate(source, translator_opts) do
      {:ok, translated} -> validate_translated_source(translated, scheme)
      _other -> {:error, {:invalid_source, {:source_scheme_error, scheme}}}
    end
  rescue
    _error -> {:error, {:invalid_source, {:source_scheme_error, scheme}}}
  catch
    _kind, _reason -> {:error, {:invalid_source, {:source_scheme_error, scheme}}}
  end

  defp validate_translated_source(%Path{segments: segments} = source, source_scheme)
       when is_list(segments) do
    if Enum.all?(segments, &is_binary/1),
      do: {:ok, source},
      else: invalid_translation(source_scheme)
  end

  defp validate_translated_source(%URL{} = source, source_scheme) do
    if valid_url_source?(source), do: {:ok, source}, else: invalid_translation(source_scheme)
  end

  defp validate_translated_source(
         %Object{adapter: adapter, scope: scope, key: key, revision: revision} = source,
         _scheme
       )
       when is_atom(adapter) and is_binary(scope) and is_binary(key) and
              (is_nil(revision) or is_binary(revision)),
       do: {:ok, source}

  defp validate_translated_source(
         %Reference{
           adapter: adapter,
           id: id,
           revision: revision,
           metadata: metadata
         } = source,
         scheme
       )
       when is_atom(adapter) and is_binary(id) and (is_nil(revision) or is_binary(revision)) do
    if Keyword.keyword?(metadata), do: {:ok, source}, else: invalid_translation(scheme)
  end

  defp validate_translated_source(_source, scheme), do: invalid_translation(scheme)

  defp invalid_translation(scheme),
    do: {:error, {:invalid_source, {:source_scheme_error, scheme}}}

  defp valid_url_source?(%URL{} = source) do
    valid_url_origin?(source) and valid_url_path?(source.path) and
      optional_binary?(source.query)
  end

  defp valid_url_origin?(%URL{scheme: scheme, host: host, port: port})
       when scheme in [:http, :https] and is_binary(host) and host != "",
       do: valid_port?(port)

  defp valid_url_origin?(%URL{}), do: false

  defp valid_url_path?(path) when is_list(path), do: Enum.all?(path, &is_binary/1)
  defp valid_url_path?(_path), do: false

  defp valid_port?(nil), do: true
  defp valid_port?(port) when is_integer(port), do: port in 1..65_535
  defp valid_port?(_port), do: false

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value)

  defp reject_object_port(source) do
    case source_port(source) do
      {:ok, nil} -> :ok
      {:ok, _port} -> {:error, :port_not_allowed}
      {:error, _reason} -> {:error, :port_not_allowed}
    end
  end

  defp source_port(source) do
    source
    |> String.split("://", parts: 2)
    |> List.last()
    |> authority()
    |> authority_port()
  end

  defp authority(rest) do
    rest
    |> String.split(["/", "?", "#"], parts: 2)
    |> hd()
  end

  defp authority_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [_host, ""] -> {:ok, nil}
      [_host, ":" <> port] -> parse_port(port)
      _other -> {:error, :invalid_port}
    end
  end

  defp authority_port(authority) do
    case String.split(authority, ":", parts: 2) do
      [_host] -> {:ok, nil}
      [_host, port] -> parse_port(port)
    end
  end

  defp parse_port(port) do
    if String.match?(port, ~r/^[0-9]+$/) do
      case Integer.parse(port) do
        {number, ""} when number in 1..65_535 -> {:ok, number}
        _invalid -> {:error, :invalid_port}
      end
    else
      {:error, :invalid_port}
    end
  end

  defp url_path_segments(nil), do: {:ok, []}
  defp url_path_segments("/"), do: {:ok, []}

  defp url_path_segments(path) do
    path
    |> String.replace_prefix("/", "")
    |> String.split("/", trim: false)
    |> decode_segments()
  end

  defp decode_segments(segments) do
    segments
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, decoded} ->
      case percent_decode(segment) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_optional(nil), do: {:ok, nil}
  defp decode_optional(value), do: percent_decode(value)

  defp percent_decode(value) do
    with :ok <- validate_percent_encoding(value) do
      {:ok, URI.decode(value)}
    end
  rescue
    ArgumentError -> {:error, :invalid_percent_encoding}
  end

  defp validate_percent_encoding(nil), do: :ok

  defp validate_percent_encoding(value) do
    if String.match?(value, @malformed_percent) do
      {:error, :invalid_percent_encoding}
    else
      :ok
    end
  end
end
