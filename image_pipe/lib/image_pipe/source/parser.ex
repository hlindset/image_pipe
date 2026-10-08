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
  #     an absolute `%Plan.Source.URL{}`. Inner URL path segments keep their
  #     percent-encoding, and the HTTP adapter sends them as written.
  #   * `s3://` (when a configured source matches the scheme) — an
  #     `%Plan.Source.Object{}` with the query carried as its immutable
  #     revision.
  #   * a custom scheme a configured source matches — a `%Plan.Source.Path{}`
  #     tagged with that scheme, holding the part after `scheme://` split on
  #     `/`.
  #   * anything else (a scheme no configured source matches, built-in or
  #     custom, an empty source, a NUL byte, or a malformed authority) —
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

  @spec translate(String.t(), keyword()) ::
          {:ok, ImagePipe.Plan.Source.t()} | {:error, {:invalid_source, term()}}
  def translate(source, config) when is_binary(source),
    do: source |> PlanSource.normalize() |> do_translate(config)

  defp do_translate("", _config), do: {:error, {:invalid_source, :empty_source}}

  # No file system path or object key can hold a NUL byte.
  defp do_translate(source, config) when is_binary(source) do
    if String.contains?(source, <<0>>),
      do: {:error, {:invalid_source, :nul_byte}},
      else: classify(source, config)
  end

  defp classify(source, config) do
    case scheme(source) do
      {:ok, scheme} -> url_translate(String.downcase(scheme), source, config)
      :error -> {:ok, path_translate(source)}
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
    if digits?(port) do
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
    if Enum.all?(segments, &(validate_percent_encoding(&1) == :ok)),
      do: {:ok, Enum.map(segments, &encode_path_segment/1)},
      else: {:error, :invalid_percent_encoding}
  end

  @doc false
  # Escapes only the bytes that can't appear raw in a URL path segment, so a
  # segment that is already percent-encoded keeps its exact spelling. Origins
  # that sign their paths compare it byte for byte.
  def encode_path_segment(segment), do: URI.encode(segment, &path_char?/1)

  defp path_char?(char), do: URI.char_unreserved?(char) or char in ~c"!$&'()*+,;=:@%"

  defp percent_decode(value) do
    with :ok <- validate_percent_encoding(value) do
      {:ok, URI.decode(value)}
    end
  rescue
    ArgumentError -> {:error, :invalid_percent_encoding}
  end

  defp validate_percent_encoding(nil), do: :ok

  defp validate_percent_encoding(value) do
    if malformed_percent?(value) do
      {:error, :invalid_percent_encoding}
    else
      :ok
    end
  end

  defguardp hex?(byte) when byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f

  # A "%" not followed by two hex digits.
  defp malformed_percent?(value) do
    case :binary.match(value, "%") do
      :nomatch ->
        false

      {at, 1} ->
        case binary_part(value, at + 1, byte_size(value) - at - 1) do
          <<a, b, rest::binary>> when hex?(a) and hex?(b) -> malformed_percent?(rest)
          _malformed -> true
        end
    end
  end

  # Grammar checks scan bytes: OTP 28 and later rebuild a regex at every use.

  # The scheme of a `[a-zA-Z][a-zA-Z0-9+.-]*://` prefix.
  defp scheme(<<first, rest::binary>> = source) when first in ?a..?z or first in ?A..?Z,
    do: scheme(rest, source, 1)

  defp scheme(_source), do: :error

  defp scheme("://" <> _rest, source, length), do: {:ok, binary_part(source, 0, length)}

  defp scheme(<<char, rest::binary>>, source, length)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?+, ?., ?-],
       do: scheme(rest, source, length + 1)

  defp scheme(_rest, _source, _length), do: :error

  defp digits?(<<char, rest::binary>>) when char in ?0..?9, do: rest == "" or digits?(rest)
  defp digits?(_string), do: false
end
