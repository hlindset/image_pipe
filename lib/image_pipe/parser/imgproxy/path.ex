defmodule ImagePipe.Parser.Imgproxy.Path do
  @moduledoc false

  alias ImagePipe.Parser.Imgproxy.Format
  alias ImagePipe.Parser.Imgproxy.PercentEncoding
  alias ImagePipe.Parser.Imgproxy.SourceEncryption

  def split_endpoint(%Plug.Conn{} = conn) do
    case parser_request_path(conn) do
      "/info/" <> rest -> {:info, %{conn | request_path: "/" <> rest}}
      "/info" -> {:info, %{conn | request_path: "/"}}
      _ -> :image
    end
  end

  def extract(%Plug.Conn{} = conn) do
    case parser_request_path(conn) do
      "/" ->
        {:error, :missing_signature}

      "/" <> raw_path ->
        raw_path
        |> :binary.split("/", [:global])
        |> raw_path_parts()

      _path ->
        {:error, :missing_signature}
    end
  end

  def split_source(path_info) do
    split_source(path_info, [])
  end

  def parse_source(source_kind, source_path), do: parse_source(source_kind, source_path, [])
  def parse_source(:plain, source_path, _opts), do: parse_plain_source(source_path)
  def parse_source(:encoded, source_path, opts), do: parse_encoded_source(source_path, opts)
  def parse_source(:encrypted, source_path, opts), do: parse_encrypted_source(source_path, opts)

  def parse_source_no_extension(:plain, source_path, _opts) do
    encoded = Enum.join(source_path, "/")

    case encoded do
      "" -> {:error, {:missing_source_identifier, "plain"}}
      source -> decode_source_path(source, nil)
    end
  end

  def parse_source_no_extension(:encoded, source_path, opts) do
    case encoded_source_value(source_path, opts) do
      "" -> {:error, {:missing_source_identifier, "encoded"}}
      value -> decode_encoded_source(value, nil)
    end
  end

  def parse_source_no_extension(:encrypted, source_path, opts) do
    source_encryption = Keyword.get(opts, :source_url_encryption)

    case encoded_source_value(source_path, opts) do
      "" -> {:error, {:missing_source_identifier, "encrypted"}}
      value -> decode_encrypted_source(value, nil, source_encryption)
    end
  end

  def parse_plain_source(source_path) do
    encoded = Enum.join(source_path, "/")

    case String.split(encoded, "@") do
      [""] ->
        {:error, {:missing_source_identifier, "plain"}}

      [source] ->
        decode_source_path(source, nil)

      ["", _extension] ->
        {:error, {:missing_source_identifier, "plain"}}

      [source, ""] ->
        decode_source_path(source, nil)

      [source, extension] ->
        case Format.parse(extension) do
          {:ok, format} -> decode_source_path(source, format)
          {:error, _reason} = error -> error
        end

      _parts ->
        {:error, {:multiple_output_extension_separators, encoded}}
    end
  end

  defp split_source([], _options), do: {:error, :missing_source_kind}

  defp split_source(["plain"], _options), do: {:error, {:missing_source_identifier, "plain"}}

  defp split_source(["plain" | source_path], options),
    do: {:ok, Enum.reverse(options), :plain, source_path}

  defp split_source(["enc"], options), do: {:ok, Enum.reverse(options), :encrypted, []}

  defp split_source(["enc" | source_path], options),
    do: {:ok, Enum.reverse(options), :encrypted, source_path}

  defp split_source(["-" | segments], options) do
    case Enum.member?(segments, "plain") do
      true -> split_source(segments, ["-" | options])
      false -> {:ok, Enum.reverse(options), :encoded, ["-" | segments]}
    end
  end

  defp split_source([segment | segments], options) do
    case classify_pre_source_segment(segment) do
      :option ->
        split_source(segments, [segment | options])

      :source_start ->
        {:ok, Enum.reverse(options), :encoded, [segment | segments]}
    end
  end

  defp classify_pre_source_segment(segment) do
    case String.contains?(segment, ":") do
      true -> :option
      false -> :source_start
    end
  end

  defp parse_encoded_source(source_path, opts) do
    source_path
    |> encoded_source_value(opts)
    |> parse_encoded_source_value("encoded", &decode_encoded_source/2)
  end

  defp parse_encrypted_source(source_path, opts) do
    source_encryption = Keyword.get(opts, :source_url_encryption)

    source_path
    |> encoded_source_value(opts)
    |> parse_encoded_source_value("encrypted", fn source, source_format ->
      decode_encrypted_source(source, source_format, source_encryption)
    end)
  end

  defp parse_encoded_source_value(encoded, source_kind, decode_fun) do
    case String.split(encoded, ".") do
      [""] ->
        missing_encoded_source(source_kind)

      [source] ->
        decode_fun.(source, nil)

      ["", _extension] ->
        missing_encoded_source(source_kind)

      [source, ""] ->
        decode_fun.(source, nil)

      [source, extension] ->
        case Format.parse(extension) do
          {:ok, format} -> decode_fun.(source, format)
          {:error, _reason} = error -> error
        end

      _parts ->
        {:error, {:multiple_output_extension_separators, encoded}}
    end
  end

  defp encoded_source_value(source_path, opts) do
    source_path
    |> maybe_drop_seo_filename(opts)
    |> Enum.join()
  end

  defp maybe_drop_seo_filename(source_path, opts) do
    case Keyword.get(opts, :base64_url_includes_filename, false) and
           match?([_, _ | _], source_path) do
      true -> Enum.drop(source_path, -1)
      false -> source_path
    end
  end

  defp missing_encoded_source("encrypted"), do: {:error, :invalid_encrypted_source}

  defp missing_encoded_source(source_kind),
    do: {:error, {:missing_source_identifier, source_kind}}

  defp decode_encoded_source(source, source_format) do
    source
    |> String.trim_trailing("=")
    |> Base.url_decode64(padding: false)
    |> case do
      {:ok, decoded} -> validate_decoded_source(decoded, source_format)
      :error -> {:error, {:invalid_encoded_source, :base64}}
    end
  end

  defp validate_decoded_source(decoded, source_format) do
    case String.valid?(decoded) do
      true -> {:ok, decoded, source_format}
      false -> {:error, {:invalid_encoded_source, :utf8}}
    end
  end

  defp decode_encrypted_source(source, source_format, source_encryption) do
    case SourceEncryption.decrypt_source(source, source_encryption) do
      {:ok, decrypted_source} -> {:ok, decrypted_source, source_format}
      {:error, :missing_source_url_encryption_key} -> {:error, :missing_source_url_encryption_key}
      {:error, _reason} -> {:error, :invalid_encrypted_source}
    end
  end

  defp parser_request_path(%Plug.Conn{request_path: request_path, script_name: []}),
    do: request_path

  defp parser_request_path(%Plug.Conn{request_path: request_path, script_name: script_name}) do
    prefix = "/" <> Enum.join(script_name, "/")

    cond do
      request_path == prefix ->
        "/"

      String.starts_with?(request_path, prefix <> "/") ->
        String.replace_prefix(request_path, prefix, "")

      true ->
        request_path
    end
  end

  defp raw_path_parts(["" | _raw_path_info]), do: {:error, :missing_signature}
  defp raw_path_parts([_signature]), do: {:error, :missing_signed_path}

  defp raw_path_parts([signature | raw_path_info]) do
    signed_path =
      raw_path_info
      |> Enum.join("/")
      |> then(&("/" <> &1))
      |> fix_path()

    {:ok, signature, signed_path, path_info_from_signed_path(signed_path)}
  end

  defp path_info_from_signed_path(""), do: []
  defp path_info_from_signed_path("/" <> path), do: :binary.split(path, "/", [:global])

  defp fix_path(path) do
    case :binary.split(path, "/plain/") do
      [options, plain_url] ->
        fix_options_path(options) <> "/plain/" <> fix_plain_url_path(plain_url)

      [options] ->
        fix_options_path(options)
    end
  end

  defp fix_options_path(options), do: String.replace(options, ~r/%3a/i, ":")

  defp fix_plain_url_path(plain_url) do
    case Regex.run(~r/^(\S+):\/([^\/])/, plain_url) do
      [match, "local", first] ->
        String.replace_prefix(plain_url, match, "local:///" <> first)

      [match, scheme, first] ->
        String.replace_prefix(plain_url, match, scheme <> "://" <> first)

      nil ->
        plain_url
    end
  end

  defp decode_source_path(source, source_format) do
    with :ok <- validate_percent_encoded_segments(source) do
      {:ok, source, source_format}
    end
  end

  defp validate_percent_encoded_segments(source) do
    source
    |> String.split("/", trim: false)
    |> PercentEncoding.decode_segments()
    |> case do
      {:ok, _decoded_segments} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
