defmodule ImagePipe.Response.Sender do
  @moduledoc false

  import Plug.Conn,
    only: [
      chunk: 2,
      put_resp_content_type: 2,
      put_resp_content_type: 3,
      put_resp_header: 3,
      send_chunked: 2,
      send_resp: 3
    ]

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Error
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Json
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Telemetry

  @not_modified_header_allowlist ~w(cache-control date etag expires vary)

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), [{String.t(), [String.t()]}], CacheHeaders.t()}

  @type error() ::
          {:processing, term(), [{String.t(), String.t()}]}

  @plan_validation_error_tags [
    :unsupported_source,
    :invalid_output_plan,
    :invalid_expires,
    :invalid_cachebuster,
    :invalid_response_plan,
    :invalid_pipeline_plan,
    :invalid_pipeline_operation,
    :unprojectable_operation_for_cache_adapter,
    :detector_unavailable
  ]

  @spec send_result(
          Plug.Conn.t(),
          {:ok, delivery()}
          | {:error, error()},
          keyword()
        ) :: Plug.Conn.t()
  def send_result(
        %Plug.Conn{} = conn,
        {:ok,
         {:cache_entry, %Entry{} = entry, %Response{} = response, %CacheHeaders{} = prepared}},
        opts
      ) do
    send_cache_entry(conn, entry, response, prepared, opts)
  end

  def send_result(
        %Plug.Conn{} = conn,
        {:ok,
         {:prepared_stream, %PreparedStream{} = prepared_stream, %Response{} = response,
          %CacheHeaders{} = prepared}},
        opts
      ) do
    send_prepared_stream(conn, prepared_stream, response, prepared, opts)
  end

  def send_result(
        %Plug.Conn{} = conn,
        {:ok, {:rendered, content_type, body, offers, %CacheHeaders{} = prepared}},
        _opts
      ) do
    {negotiated_type, vary?} = negotiate_render(conn, content_type, offers)

    conn
    |> apply_render_cache_headers(prepared)
    |> maybe_put_vary(vary?)
    |> Json.send(negotiated_type, body)
  end

  def send_result(
        conn,
        {:error, {:processing, reason, response_headers}},
        _opts
      ) do
    handle_processing_error(conn, reason, response_headers)
  end

  @spec send_source_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_source_error(%Plug.Conn{} = conn, error),
    do: send_source_error(conn, error, [])

  @spec send_source_error(Plug.Conn.t(), term(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def send_source_error(%Plug.Conn{} = conn, _error, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(422, "invalid image source")
  end

  @spec send_redirect(Plug.Conn.t(), 303, String.t()) :: Plug.Conn.t()
  def send_redirect(%Plug.Conn{} = conn, status, location) when is_binary(location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
  end

  @spec send_method_not_allowed(Plug.Conn.t()) :: Plug.Conn.t()
  def send_method_not_allowed(%Plug.Conn{} = conn) do
    conn
    |> put_resp_header("allow", "GET, HEAD")
    |> put_resp_content_type("text/plain")
    |> send_resp(405, "method not allowed")
  end

  @spec send_not_modified(Plug.Conn.t(), CacheHeaders.t()) :: Plug.Conn.t()
  def send_not_modified(%Plug.Conn{} = conn, %CacheHeaders{} = prepared) do
    prepared
    |> not_modified_headers()
    |> Enum.reduce(conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
    |> send_resp(304, "")
  end

  defp handle_processing_error(
         conn,
         {:transform_error, {:bad_request, _detail}} = reason,
         response_headers
       ) do
    Logger.info("bad_request: #{inspect(reason)}")
    send_bad_request_error(conn, response_headers)
  end

  defp handle_processing_error(
         conn,
         {:transform_error, reason},
         response_headers
       ) do
    Logger.info("transform_error: #{inspect(reason)}")
    send_transform_error(conn, response_headers)
  end

  defp handle_processing_error(conn, {:source, error}, response_headers),
    do: send_source_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:decode, error}, response_headers),
    do: send_decode_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:unsupported_source_format, _family}, response_headers),
    do: send_decode_error(conn, :unsupported_source_format, response_headers)

  defp handle_processing_error(conn, :source_format_required, response_headers),
    do: send_decode_error(conn, :source_format_required, response_headers)

  defp handle_processing_error(conn, {:input_limit, error}, response_headers),
    do: send_input_limit_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:encode, exception, stacktrace}, response_headers),
    do: handle_encode_exception(exception, stacktrace, conn, response_headers)

  defp handle_processing_error(conn, {:encode, :empty_stream}, response_headers) do
    Logger.error("encode_error: empty_stream")
    send_encode_error(conn, response_headers)
  end

  defp handle_processing_error(conn, {:cache_write, error}, response_headers),
    do: send_cache_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:config, error}, response_headers),
    do: send_config_error(conn, error, response_headers)

  defp handle_processing_error(conn, :empty_pipeline_plan, response_headers),
    do: send_plan_validation_error(conn, :empty_pipeline_plan, response_headers)

  defp handle_processing_error(
         conn,
         {:unsupported_output_format, _format} = reason,
         response_headers
       ) do
    Logger.info("unsupported_output_format: #{inspect(reason)}")
    send_unsupported_output_format_error(conn, response_headers)
  end

  defp handle_processing_error(conn, {:render, {:decode, _} = inner}, response_headers),
    do: handle_processing_error(conn, inner, response_headers)

  defp handle_processing_error(conn, {:render, {:source, _} = inner}, response_headers),
    do: handle_processing_error(conn, inner, response_headers)

  defp handle_processing_error(
         conn,
         {:render, {:unsupported_source_format, _} = inner},
         response_headers
       ),
       do: handle_processing_error(conn, inner, response_headers)

  defp handle_processing_error(
         conn,
         {:render, :source_format_required = inner},
         response_headers
       ),
       do: handle_processing_error(conn, inner, response_headers)

  defp handle_processing_error(conn, {:render, {:input_limit, _} = inner}, response_headers),
    do: handle_processing_error(conn, inner, response_headers)

  defp handle_processing_error(conn, {:render, reason}, response_headers) do
    Logger.error("render_error: #{inspect(reason)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error rendering response")
  end

  defp handle_processing_error(conn, {tag, _value} = reason, response_headers)
       when tag in @plan_validation_error_tags do
    send_plan_validation_error(conn, reason, response_headers)
  end

  defp send_plan_validation_error(conn, reason, response_headers) do
    Logger.info("plan_validation_error: #{inspect(reason)}")
    send_transform_error(conn, response_headers)
  end

  defp send_unsupported_output_format_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(501, "requested output format is not supported by this server")
  end

  defp send_decode_error(%Plug.Conn{} = conn, _error, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(415, "source response is not a supported image")
  end

  defp send_input_limit_error(%Plug.Conn{} = conn, error, response_headers) do
    Logger.info("input_limit_error: #{inspect(error)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(413, "source image is too large")
  end

  defp send_bad_request_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "bad request")
  end

  defp send_transform_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(422, "invalid image transform")
  end

  defp send_cache_entry(
         %Plug.Conn{} = conn,
         %Entry{} = entry,
         %Response{} = response,
         %CacheHeaders{} = prepared,
         opts
       ) do
    with {:ok, headers} <- Entry.cacheable_headers(entry.headers),
         merged_headers <- merge_delivery_headers(conn, headers, prepared),
         {:ok, headers} <- delivery_headers(merged_headers, response, entry.content_type) do
      Telemetry.execute(
        Telemetry.telemetry_opts(opts),
        [:http_cache, :cache_hit, :headers],
        %{},
        %{
          etag: prepared.etag != nil,
          generated_cache_headers: prepared.headers != [],
          representation_headers: prepared.representation_headers != []
        }
      )

      send_normalized_cache_entry(conn, entry, headers)
    else
      {:error, error} -> send_cache_error(conn, error)
    end
  end

  defp send_normalized_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry, headers) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        put_resp_header(conn, name, value)
      end)

    conn
    |> put_resp_content_type(entry.content_type, nil)
    |> send_resp(200, entry.body)
  end

  defp send_prepared_stream(
         %Plug.Conn{} = conn,
         %PreparedStream{} = prepared_stream,
         %Response{},
         %CacheHeaders{} = prepared,
         opts
       ) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    Telemetry.span(
      telemetry_opts,
      [:deliver],
      output_metadata(prepared_stream.resolved_output),
      fn ->
        prepared_stream = merge_prepared_stream_headers(conn, prepared_stream, prepared)
        {conn, outcome} = do_send_prepared_stream(conn, prepared_stream)

        {conn, deliver_stop_metadata(outcome, conn, prepared_stream.resolved_output)}
      end
    )
  end

  defp do_send_prepared_stream(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
    case stream_prepared_chunks(conn, prepared_stream) do
      {:ok, conn} ->
        {conn, :ok}

      {:error, conn, reason} ->
        _cancel_result = prepared_stream.cancel.()
        {mark_prepared_stream_error(conn, reason), {:error, reason}}
    end
  end

  defp stream_prepared_chunks(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
    conn = prepare_chunked_conn(conn, prepared_stream)

    case open_prepared_chunked(conn) do
      {:ok, conn} ->
        send_prepared_first_chunk(conn, prepared_stream)

      {:error, conn, reason} ->
        {:error, conn, reason}
    end
  end

  defp open_prepared_chunked(%Plug.Conn{} = conn) do
    {:ok, send_chunked(conn, 200)}
  rescue
    exception ->
      {:error, mark_send_processing_error(conn), {:encode, {exception, __STACKTRACE__}}}
  catch
    kind, reason ->
      {:error, mark_send_processing_error(conn), {kind, reason}}
  end

  defp prepare_chunked_conn(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
    conn
    |> put_resp_headers(prepared_stream.headers)
    |> put_resp_content_type(prepared_stream.content_type, nil)
    |> Map.put(:status, 200)
  end

  defp send_prepared_first_chunk(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
    case chunk(conn, prepared_stream.first_chunk) do
      {:ok, conn} ->
        continue_prepared_stream(conn, prepared_stream)

      {:error, reason} ->
        {:error, conn, {:client_closed, reason}}
    end
  end

  defp continue_prepared_stream(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
    case prepared_stream.next.() do
      {:chunk, chunk} ->
        send_prepared_stream_chunk(conn, prepared_stream, chunk)

      :done ->
        {:ok, conn}

      {:error, reason} ->
        {:error, conn, reason}
    end
  rescue
    exception ->
      {:error, mark_send_processing_error(conn), {:encode, {exception, __STACKTRACE__}}}
  catch
    kind, reason ->
      {:error, mark_send_processing_error(conn), {kind, reason}}
  end

  defp send_prepared_stream_chunk(
         %Plug.Conn{} = conn,
         %PreparedStream{} = prepared_stream,
         chunk
       ) do
    case chunk(conn, chunk) do
      {:ok, conn} ->
        continue_prepared_stream(conn, prepared_stream)

      {:error, reason} ->
        {:error, conn, {:client_closed, reason}}
    end
  end

  defp send_cache_error(%Plug.Conn{} = conn, error),
    do: send_cache_error(conn, error, [])

  defp send_cache_error(%Plug.Conn{} = conn, error, response_headers) do
    Logger.error("cache_error: #{inspect(error)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "cache error")
  end

  defp send_config_error(%Plug.Conn{} = conn, error, response_headers) do
    Logger.error("config_error: #{inspect(error)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "configuration error")
  end

  defp handle_encode_exception(exception, stacktrace, %Plug.Conn{} = conn, response_headers) do
    Logger.error("encode_error: #{Exception.format(:error, exception, stacktrace)}")

    conn =
      if conn.state in [:unset, :set] do
        send_encode_error(conn, response_headers)
      else
        conn
      end

    mark_send_processing_error(conn)
  end

  defp mark_send_processing_error(%Plug.Conn{} = conn),
    do: Plug.Conn.put_private(conn, :image_pipe_send_result, :processing_error)

  defp mark_prepared_stream_error(%Plug.Conn{} = conn, {:client_closed, reason}) do
    Logger.info("prepared_stream_client_closed: #{inspect(reason)}")
    conn
  end

  defp mark_prepared_stream_error(%Plug.Conn{} = conn, reason) do
    Logger.error("prepared_stream_error: #{inspect(reason)}")
    mark_send_processing_error(conn)
  end

  defp delivery_headers(response_headers, %Response{} = response, content_type) do
    with {:ok, content_disposition} <- Response.content_disposition(response, content_type) do
      {:ok, response_headers ++ [{"content-disposition", content_disposition}]}
    end
  end

  defp merge_prepared_stream_headers(
         %Plug.Conn{} = conn,
         %PreparedStream{} = prepared_stream,
         %CacheHeaders{} = prepared
       ) do
    headers = merge_delivery_headers(conn, prepared_stream.headers, prepared)
    %{prepared_stream | headers: headers}
  end

  defp negotiate_render(_conn, base_type, []), do: {base_type, false}

  defp negotiate_render(%Plug.Conn{} = conn, base_type, offers) do
    accept = accept_header(conn)

    case Enum.find(offers, fn {_ct, tokens} ->
           Enum.any?(tokens, &String.contains?(accept, &1))
         end) do
      {offered_type, _tokens} -> {offered_type, true}
      nil -> {base_type, true}
    end
  end

  defp accept_header(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "accept") do
      [value | _] -> value
      [] -> ""
    end
  end

  defp maybe_put_vary(conn, false), do: conn
  defp maybe_put_vary(conn, true), do: Plug.Conn.put_resp_header(conn, "vary", "Accept")

  defp apply_render_cache_headers(%Plug.Conn{} = conn, %CacheHeaders{} = prepared) do
    # Reuse the same delivery-header precedence as image responses: prepared cache /
    # representation headers are merged, but host headers already set on the conn are
    # respected (a host plug's stricter cache policy is not silently relaxed).
    conn
    |> merge_delivery_headers([], prepared)
    |> Enum.reduce(conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
  end

  defp merge_delivery_headers(%Plug.Conn{} = conn, delivery_headers, %CacheHeaders{} = prepared) do
    authoritative_names = authoritative_header_names(prepared.representation_headers)

    []
    |> merge_header_list(prepared.headers)
    |> merge_authoritative_header_list(prepared.representation_headers)
    |> merge_header_list(delivery_headers)
    |> reject_existing_conn_headers(conn, authoritative_names)
  end

  defp merge_header_list(headers, new_headers) do
    Enum.reduce(new_headers, headers, fn {name, value}, headers ->
      name = String.downcase(name)

      if header_present?(headers, name) do
        headers
      else
        headers ++ [{name, value}]
      end
    end)
  end

  defp header_present?(headers, name) do
    Enum.any?(headers, fn {existing_name, _value} -> String.downcase(existing_name) == name end)
  end

  defp merge_authoritative_header_list(headers, new_headers) do
    Enum.reduce(new_headers, headers, fn {name, value}, headers ->
      name = String.downcase(name)

      headers
      |> Enum.reject(fn {existing_name, _value} -> String.downcase(existing_name) == name end)
      |> Kernel.++([{name, value}])
    end)
  end

  defp reject_existing_conn_headers(headers, %Plug.Conn{} = conn, authoritative_names) do
    Enum.reject(headers, fn {name, _value} ->
      name = String.downcase(name)
      name not in authoritative_names and host_resp_header?(conn, name)
    end)
  end

  defp authoritative_header_names(headers) do
    headers
    |> Enum.map(fn {name, _value} -> String.downcase(name) end)
    |> Enum.uniq()
  end

  defp host_resp_header?(conn, "cache-control") do
    conn
    |> Plug.Conn.get_resp_header("cache-control")
    |> CacheHeaders.host_cache_control?()
  end

  defp host_resp_header?(conn, name), do: Plug.Conn.get_resp_header(conn, name) != []

  defp put_resp_headers(%Plug.Conn{} = conn, response_headers) do
    Enum.reduce(response_headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp send_encode_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error encoding image")
  end

  defp not_modified_headers(%CacheHeaders{} = prepared) do
    prepared.headers
    |> Kernel.++(prepared.representation_headers)
    |> Enum.filter(fn {name, _value} ->
      String.downcase(name) in @not_modified_header_allowlist
    end)
  end

  defp output_metadata(%Resolved{format: format}), do: %{output_format: format}

  defp deliver_ok_metadata(:ok, %Plug.Conn{status: status}, %Resolved{} = resolved_output),
    do: Map.merge(%{result: :ok, status: status}, output_metadata(resolved_output))

  defp deliver_stop_metadata(:ok, %Plug.Conn{} = conn, %Resolved{} = resolved_output) do
    deliver_ok_metadata(:ok, conn, resolved_output)
  end

  defp deliver_stop_metadata(
         {:error, {:client_closed, _reason}},
         %Plug.Conn{status: status},
         %Resolved{} = resolved_output
       ) do
    Map.merge(
      %{
        result: :client_closed,
        stream_phase: :client,
        error: :client_closed,
        status: status
      },
      output_metadata(resolved_output)
    )
  end

  defp deliver_stop_metadata(
         {:error, reason},
         %Plug.Conn{status: status},
         %Resolved{} = resolved_output
       ) do
    Map.merge(
      %{
        result: :processing_error,
        stream_phase: stream_error_phase(reason),
        error: stream_error_tag(reason),
        status: status
      },
      output_metadata(resolved_output)
    )
  end

  defp stream_error_phase({phase, _reason}) when phase in [:source, :decode, :output, :encode],
    do: phase

  defp stream_error_phase(_reason), do: :encode

  defp stream_error_tag({phase, reason}) when phase in [:source, :decode, :output, :encode],
    do: Error.tag(reason)

  defp stream_error_tag(reason), do: Error.tag(reason)
end
