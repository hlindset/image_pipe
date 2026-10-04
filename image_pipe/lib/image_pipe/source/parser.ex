defmodule ImagePipe.Source.Parser do
  # Translates a decoded source string into `ImagePipe.Plan.Source`.
  #
  # `translate/2` consumes a source string, with any outer transport encoding
  # already decoded, and classifies it:
  #
  #   * no `scheme://` prefix — a root-relative `%Plan.Source.Path{}`. The
  #     decoded string is split into segments on `/` with no further decoding.
  #     An optional leading slash is normalized for ordinary root-relative paths.
  #   * `http://` or `https://` (when a configured source matches the scheme) —
  #     an absolute `%Plan.Source.URL{}`. Inner URL path escapes are decoded
  #     once here and re-encoded by the HTTP adapter.
  #   * `s3://` (when a configured source matches the scheme) — an
  #     `%Plan.Source.Object{}` with the query carried as its immutable
  #     revision.
  #   * a custom scheme a configured source matches — a `%Plan.Source.Path{}`
  #     tagged with that scheme, holding the part after `scheme://` split on
  #     `/`.
  #   * anything else (a scheme no configured source matches, built-in or
  #     custom, an empty source, or a malformed authority) —
  #     `{:error, {:invalid_source, reason}}`.
  #
  # `ImagePipe.Source.resolve/3` consumes the returned `Plan.Source.t()`
  # unchanged.
  @moduledoc false

  alias ImagePipe.Plan.Source, as: PlanSource
  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source.Routes

  @http_schemes %{"http" => :http, "https" => :https}
  @scheme_prefix ~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\//
  @malformed_percent ~r/%($|[^0-9A-Fa-f]|[0-9A-Fa-f]$|[0-9A-Fa-f][^0-9A-Fa-f])/

  @spec translate(String.t(), keyword()) ::
          {:ok, ImagePipe.Plan.Source.t()} | {:error, {:invalid_source, term()}}
  def translate(source, config) when is_binary(source),
    do: source |> PlanSource.normalize() |> do_translate(config)

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

  defp url_translate(scheme, source, config) do
    if Routes.scheme?(Keyword.get(config, :sources, %Routes{}), scheme),
      do: scheme_translate(scheme, source),
      else: {:error, {:invalid_source, {:unsupported_scheme, scheme}}}
  end

  defp scheme_translate(scheme, source) when is_map_key(@http_schemes, scheme) do
    build_url(Map.fetch!(@http_schemes, scheme), source, URI.parse(source))
  end

  defp scheme_translate("s3", source) do
    build_s3(source, URI.parse(source))
  end

  defp scheme_translate(scheme, source) do
    rest = binary_part(source, byte_size(scheme) + 3, byte_size(source) - byte_size(scheme) - 3)
    {:ok, %Path{scheme: scheme, segments: String.split(rest, "/")}}
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
         {:ok, revision} <- object_revision(uri.query) do
      {:ok,
       %Object{
         scheme: "s3",
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
      {:ok, key} -> reject_dot_segments(key)
      error -> error
    end
  end

  # A proxy or S3-compatible gateway that normalizes paths would resolve `.`
  # and `..` segments, reaching keys or buckets outside the allowlist. This
  # isn't `Path.safe_relative/1`: S3 keys are literal, and empty segments
  # (`images//cat.jpg`) name distinct objects.
  defp reject_dot_segments(key) do
    if key |> String.split("/") |> Enum.any?(&(&1 in [".", ".."])),
      do: {:error, :dot_segment_in_object_key},
      else: {:ok, key}
  end

  # An empty query (`cat.jpg?`) names no version.
  defp object_revision(query) when query in [nil, ""], do: {:ok, nil}
  defp object_revision(query), do: percent_decode(query)

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
