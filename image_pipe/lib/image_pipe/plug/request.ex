defmodule ImagePipe.Plug.Request do
  @moduledoc false

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Execution
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Presets
  alias ImagePipe.Processing
  alias ImagePipe.Security
  alias ImagePipe.Source.Parser, as: SourceParser

  # Verify → lex → decrypt → parse. Returns the telemetry stop metadata with
  # the result so the Runner's parse span can report the signing key index.
  def parse(%Plug.Conn{} = conn, config) do
    path = mount_relative_path!(conn)
    {sig, signed_path} = Path.split_signature(path)

    result =
      with {:ok, key_index} <- Security.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(path, conn.query_string) |> normalize_lex_error(),
           {:ok, lexed} <- decrypt_source(lexed, config),
           {:ok, config} <- presets(lexed, config),
           {:ok, request} <- Parser.parse(lexed, config),
           {:ok, request} <- decrypt_watermarks(request, config) do
        {_marker, source, _span} = lexed.source
        {request, source, key_index}
      end

    case result do
      {%Spec{} = request, source, key_index} ->
        {{:ok, request, source}, %{result: :ok, sig_key_index: key_index}}

      {:error, _reason} = error ->
        # Deliberately NO error tag — preserving the chain's parse stop shape.
        {error, %{result: :error}}
    end
  end

  # Request-time preset lookup replaces the static map with the request's
  # compiled closure. Static-only requests skip it.
  defp presets(lexed, config) do
    with {:ok, presets} <- Presets.for_request(Parser.preset_names(lexed), config),
         do: {:ok, Keyword.put(config, :presets, presets)}
  end

  def prepare(%Spec{} = request, source, config, accept_header) do
    with {:ok, policy} <- Processing.prepare(request, config, accept_header),
         {:ok, plan_source} <- SourceParser.translate(source, config),
         {:ok, watermarks} <- Execution.watermark_sources(request, config) do
      {:ok, plan_source, watermarks, policy}
    end
  end

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  defp decrypt_source(%{source: {:enc, token, span}} = lexed, config) do
    case Security.decrypt_source(token, config) do
      {:ok, source} -> {:ok, %{lexed | source: {:enc, source, span}}}
      {:error, :invalid_concealed_source} = error -> error
    end
  end

  defp decrypt_source(lexed, _config), do: {:ok, lexed}

  defp decrypt_watermarks(%Spec{groups: groups} = request, config) do
    groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, groups} ->
      case decrypt_watermark(group, config) do
        {:ok, group} -> {:cont, {:ok, [group | groups]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, %{request | groups: Enum.reverse(groups)}}
      error -> error
    end
  end

  defp decrypt_watermark(%{watermark: %{asset: {:enc, token}} = watermark} = group, config) do
    with {:ok, source} <- Security.decrypt_source(token, config) do
      {:ok, %{group | watermark: %{watermark | asset: {:src, source}}}}
    end
  end

  defp decrypt_watermark(group, _config), do: {:ok, group}

  # Strips `conn.script_name` from `conn.request_path` as a raw prefix.
  # Because Plug decodes `script_name`, mount paths must use canonical
  # unescaped ASCII. Other mount paths raise at request time as host
  # misconfiguration (500-class).
  def mount_relative_path!(%Plug.Conn{request_path: request_path, script_name: script_name}) do
    prefix = mount_prefix!(script_name)

    case strip_prefix(request_path, prefix) do
      {:ok, rest} ->
        rest

      :error ->
        raise ArgumentError,
              "ImagePipe.Plug: request_path #{inspect(request_path)} does not " <>
                "start with the mount prefix #{inspect(prefix)} derived from script_name " <>
                "#{inspect(script_name)}"
    end
  end

  defp mount_prefix!([]), do: ""

  defp mount_prefix!(segments) do
    Enum.map_join(segments, "", fn segment ->
      if canonical_mount_segment?(segment) do
        "/" <> segment
      else
        raise ArgumentError,
              "ImagePipe.Plug: mount path segment #{inspect(segment)} is not " <>
                "canonical unescaped ASCII (non-canonical/escaped mount paths are " <>
                "unsupported in v1; a config-supplied raw mount prefix is a future " <>
                "escape hatch)"
      end
    end)
  end

  # A segment built only from RFC 3986 unreserved characters is guaranteed
  # byte-identical between conn.request_path (raw) and conn.script_name
  # (decoded) — those characters are never percent-encoded by a canonical
  # client. Anything else (including "%" itself) makes the round trip
  # through percent-encoding ambiguous, so it's rejected.
  defp canonical_mount_segment?(segment) do
    segment != "" and
      segment
      |> :binary.bin_to_list()
      |> Enum.all?(&mount_unreserved_byte?/1)
  end

  defp mount_unreserved_byte?(byte) do
    byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?-, ?., ?_, ?~]
  end

  defp strip_prefix(request_path, prefix) do
    if String.starts_with?(request_path, prefix) do
      {:ok,
       binary_part(request_path, byte_size(prefix), byte_size(request_path) - byte_size(prefix))}
    else
      :error
    end
  end
end
