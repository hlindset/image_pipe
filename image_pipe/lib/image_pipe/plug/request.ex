defmodule ImagePipe.Plug.Request do
  @moduledoc false

  alias ImagePipe.API.Diagnostic
  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Presets
  alias ImagePipe.Security

  # Verify → lex → decrypt → parse. Returns the telemetry stop metadata with
  # the result so the Runner's parse span can report the signing key index.
  def parse(%Plug.Conn{} = conn, config) do
    path = mount_relative_path(conn)
    {sig, signed_path} = Path.split_signature(path)

    result =
      with {:ok, key_index} <- Security.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(path, conn.query_string) |> normalize_lex_error(),
           {:ok, lexed} <- decrypt_source(lexed, config),
           {:ok, presets} <- presets(lexed, config),
           {:ok, request} <- Parser.parse(lexed, Keyword.put(config, :presets, presets)),
           {:ok, request} <- decrypt_watermarks(request, path, config) do
        {_marker, source, _span} = lexed.source
        {request, source, key_index}
      end

    case result do
      {%Spec{} = request, source, nil} ->
        {{:ok, request, source}, %{result: :ok}}

      {%Spec{} = request, source, key_index} ->
        {{:ok, request, source}, %{result: :ok, sig_key_index: key_index}}

      {:error, _reason} = error ->
        # The request span reports the error's tag, so the parse span's stop
        # carries only the result.
        {error, %{result: :error}}
    end
  end

  # The presets this request's parse sees: the static map, or with a
  # request-time lookup, the presets it fetched compiled over that map.
  # Static-only requests skip the option pass that finds the names, which
  # `Parser.parse/2` would repeat.
  defp presets(lexed, config) do
    case config[:preset_lookup] do
      nil ->
        {:ok, Keyword.fetch!(config, :presets)}

      _lookup ->
        with {:ok, names} <- Parser.preset_names(lexed),
             do: Presets.for_request(names, config)
    end
  end

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  # A mount without source encryption keys rejects concealed sources as a
  # malformed request, as it does a signature without signing keys. A token no
  # key decrypts reads as a missing source, so tokens can't be probed.
  defp decrypt_source(%{source: {:enc, token, span}} = lexed, config) do
    case Security.decrypt_source(token, config) do
      {:ok, source} -> {:ok, %{lexed | source: {:enc, source, span}}}
      {:error, :invalid_concealed_source} = error -> error
      {:error, :source_encryption_disabled} -> encryption_disabled("enc/", span)
    end
  end

  defp decrypt_source(lexed, _config), do: {:ok, lexed}

  defp encryption_disabled(marker, span) do
    {:error,
     {:invalid_request,
      [
        %Diagnostic{
          reason: :source_encryption_disabled,
          message: "#{marker} is not accepted: no source encryption keys are configured",
          spans: [span]
        }
      ]}}
  end

  defp decrypt_watermarks(%Spec{groups: groups} = request, path, config) do
    groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, groups} ->
      case decrypt_watermark(group, path, config) do
        {:ok, group} -> {:cont, {:ok, [group | groups]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, %{request | groups: Enum.reverse(groups)}}
      error -> error
    end
  end

  defp decrypt_watermark(%{watermark: %{asset: {:enc, token}} = watermark} = group, path, config) do
    case Security.decrypt_source(token, config) do
      {:ok, source} -> {:ok, %{group | watermark: %{watermark | asset: {:src, source}}}}
      {:error, :invalid_concealed_source} = error -> error
      {:error, :source_encryption_disabled} -> encryption_disabled("wm-enc", wm_enc_span(path))
    end
  end

  defp decrypt_watermark(group, _path, _config), do: {:ok, group}

  # A `wm-enc` a preset contributed has no segment in the path, so the
  # diagnostic spans the whole path.
  defp wm_enc_span(path) do
    case :binary.match(path, "/wm-enc=") do
      {offset, _len} ->
        [segment | _rest] =
          :binary.split(binary_part(path, offset + 1, byte_size(path) - offset - 1), "/")

        {offset + 1, byte_size(segment)}

      :nomatch ->
        {0, byte_size(path)}
    end
  end

  # Strips the mount from `conn.request_path` by segment count. Plug splits
  # `path_info` from the raw request path, dropping empty segments, and
  # `Plug.forward/4` moves those raw segments into `script_name`, so the
  # remainder keeps its raw bytes for signature checks and lexing.
  def mount_relative_path(%Plug.Conn{request_path: request_path, script_name: script_name}) do
    drop_segments(request_path, length(script_name))
  end

  defp drop_segments(path, 0), do: path

  defp drop_segments(path, count) do
    segment_and_rest = String.trim_leading(path, "/")

    case :binary.match(segment_and_rest, "/") do
      {offset, _length} ->
        drop_segments(
          binary_part(segment_and_rest, offset, byte_size(segment_and_rest) - offset),
          count - 1
        )

      :nomatch ->
        ""
    end
  end
end
