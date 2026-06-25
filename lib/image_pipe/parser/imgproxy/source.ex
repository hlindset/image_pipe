defmodule ImagePipe.Parser.Imgproxy.Source do
  @moduledoc false

  alias ImagePipe.Parser.Imgproxy.PercentEncoding
  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.URL

  @spec translate(String.t(), keyword()) :: {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}
  def translate(source, opts) when is_binary(source) do
    {source_without_query, source_query} = split_source_query(source)

    case URI.parse(source_without_query) do
      %URI{scheme: nil} ->
        path_source(source_without_query, source_query)

      %URI{scheme: "local"} = uri ->
        local_source(uri, source_query)

      %URI{scheme: scheme} = uri when scheme in ["http", "https"] ->
        url_source(uri, source_without_query, source_query)

      %URI{scheme: "s3"} = uri ->
        s3_source(uri, source_query)

      %URI{scheme: scheme} ->
        custom_source(scheme, source, opts)
    end
  end

  defp path_source(_source, source_query) when is_binary(source_query),
    do: {:error, {:unsupported_source_query, "path"}}

  defp path_source(source, nil) do
    source
    |> split_path_segments()
    |> path_segments()
  end

  defp local_source(%URI{host: host}, _source_query) when is_binary(host) and host != "",
    do: {:error, :invalid_source_path}

  defp local_source(%URI{query: query}, _source_query) when is_binary(query),
    do: {:error, {:unsupported_source_query, "local"}}

  defp local_source(%URI{fragment: fragment}, _source_query) when is_binary(fragment),
    do: {:error, :invalid_source_path}

  defp local_source(_uri, source_query) when is_binary(source_query),
    do: {:error, {:unsupported_source_query, "local"}}

  defp local_source(%URI{path: path}, nil) do
    path
    |> Kernel.||("")
    |> String.replace_prefix("/", "")
    |> split_path_segments()
    |> path_segments()
  end

  defp url_source(%URI{host: host}, _source, _source_query)
       when not is_binary(host) or host == "",
       do: {:error, :invalid_source_url}

  defp url_source(%URI{userinfo: userinfo}, _source, _source_query) when is_binary(userinfo),
    do: {:error, :invalid_source_url}

  defp url_source(%URI{fragment: fragment}, _source, _source_query) when is_binary(fragment),
    do: {:error, :invalid_source_url}

  defp url_source(%URI{} = uri, source, source_query) do
    with {:ok, path} <- uri_path_segments(uri.path || ""),
         {:ok, port} <- source_port(uri, source) do
      query = source_query || uri.query

      with {:ok, query} <- validate_optional_percent_encoding(query) do
        {:ok,
         %URL{
           scheme: String.to_existing_atom(uri.scheme),
           host: String.downcase(uri.host),
           port: port,
           path: path,
           query: query
         }}
      end
    end
  end

  defp s3_source(%URI{host: host}, _source_query) when not is_binary(host) or host == "",
    do: {:error, :invalid_source_object}

  defp s3_source(%URI{userinfo: userinfo}, _source_query) when is_binary(userinfo),
    do: {:error, :invalid_source_object}

  defp s3_source(%URI{port: port}, _source_query) when is_integer(port),
    do: {:error, :invalid_source_object}

  defp s3_source(%URI{fragment: fragment}, _source_query) when is_binary(fragment),
    do: {:error, :invalid_source_object}

  defp s3_source(%URI{} = uri, source_query) do
    key = uri.path || ""
    key = String.replace_prefix(key, "/", "")
    revision = source_query || uri.query

    with {:ok, key} <- PercentEncoding.decode(key),
         {:ok, revision} <- decode_optional(revision) do
      if key == "" do
        {:error, :invalid_source_object}
      else
        {:ok, %Object{adapter: :s3, scope: uri.host, key: key, revision: revision}}
      end
    end
  end

  defp custom_source(scheme, source, opts) do
    source_schemes = Keyword.get(opts, :source_schemes, %{})

    case source_schemes do
      %{^scheme => {translator, translator_opts}}
      when is_atom(translator) and is_list(translator_opts) ->
        translate_source(scheme, source, translator, translator_opts)

      _source_schemes ->
        {:error, {:unsupported_source_scheme, scheme}}
    end
  rescue
    _error -> {:error, {:source_scheme_error, scheme}}
  catch
    _kind, _reason -> {:error, {:source_scheme_error, scheme}}
  end

  defp translate_source(scheme, source, translator, translator_opts) do
    with {:ok, decoded_source} <- PercentEncoding.decode(source) do
      case translator.translate(decoded_source, translator_opts) do
        {:ok, %_{} = plan_source} -> {:ok, plan_source}
        {:error, _reason} -> {:error, {:source_scheme_error, scheme}}
        _other -> {:error, {:source_scheme_error, scheme}}
      end
    end
  end

  defp split_source_query(source) do
    raw_query = match_index(source, "?")
    escaped_query = escaped_query_index(source)

    case earliest_index([raw_query, escaped_query]) do
      nil ->
        {source, nil}

      {index, length} ->
        <<source_without_query::binary-size(^index), _separator::binary-size(^length),
          query::binary>> =
          source

        {source_without_query, query}
    end
  end

  defp match_index(source, pattern) do
    case :binary.match(source, pattern) do
      {index, length} -> {index, length}
      :nomatch -> nil
    end
  end

  defp escaped_query_index(source) do
    case Regex.run(~r/%3[fF]/, source, return: :index) do
      [{index, length}] -> {index, length}
      nil -> nil
    end
  end

  defp earliest_index(matches) do
    matches
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(fn {index, _length} -> index end, fn -> nil end)
  end

  defp split_path_segments(""), do: []
  defp split_path_segments(path), do: String.split(path, "/", trim: false)

  defp uri_path_segments(""), do: {:ok, []}
  defp uri_path_segments("/"), do: {:error, :invalid_source_path}

  defp uri_path_segments(path) do
    path
    |> String.replace_prefix("/", "")
    |> split_path_segments()
    |> decode_path_segments()
  end

  defp path_segments([]), do: {:error, :invalid_source_path}

  defp path_segments(segments) do
    with {:ok, decoded_segments} <- decode_path_segments(segments) do
      {:ok, %Path{segments: decoded_segments}}
    end
  end

  defp decode_path_segments(segments) do
    if Enum.any?(segments, &(&1 == "")) do
      {:error, :invalid_source_path}
    else
      PercentEncoding.decode_segments(segments)
    end
  end

  defp decode_optional(nil), do: {:ok, nil}
  defp decode_optional(value), do: PercentEncoding.decode(value)

  defp validate_optional_percent_encoding(nil), do: {:ok, nil}

  defp validate_optional_percent_encoding(value) do
    if PercentEncoding.malformed?(value) do
      {:error, {:invalid_percent_encoding, value}}
    else
      {:ok, value}
    end
  end

  defp source_port(%URI{} = uri, source) do
    source
    |> String.replace_prefix(uri.scheme <> "://", "")
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
      _other -> {:error, :invalid_source_url}
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
        {port, ""} when port in 1..65_535 -> {:ok, port}
        _invalid -> {:error, :invalid_source_url}
      end
    else
      {:error, :invalid_source_url}
    end
  end
end
