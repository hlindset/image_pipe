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
  alias ImagePipe.Debug
  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery.PreparedStream
  alias ImagePipe.Error
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Request
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Disposition
  alias ImagePipe.Telemetry

  @not_modified_header_allowlist ~w(age cache-control date etag expires vary)

  @type hit_debug() :: %{cache_key: String.t(), cache_serve_us: non_neg_integer()}

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

  def send_cache_entry(
        %Plug.Conn{} = conn,
        %Entry{} = entry,
        %Request{} = request,
        %CacheHeaders{} = prepared,
        hit_debug,
        opts
      ) do
    with {:ok, entry_headers} <- Entry.cacheable_headers(entry.headers),
         {:ok, content_disposition} <- Disposition.render(request, entry.content_type) do
      delivery_headers =
        entry_headers ++
          [{"content-disposition", content_disposition}] ++
          hit_debug_headers(entry, conn, hit_debug, opts)

      merged = merge_delivery_headers(conn, delivery_headers, prepared)

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

      send_normalized_cache_entry(conn, entry, merged)
    else
      {:error, error} -> send_cache_error(conn, error)
    end
  end

  defp hit_debug_headers(%Entry{debug: nil}, _conn, _hit_debug, _opts), do: []

  defp hit_debug_headers(%Entry{debug: %Info{} = info}, conn, hit_debug, opts) do
    if Keyword.get(opts, :debug?, false) do
      Debug.Headers.render(info,
        accept: accept_header(conn),
        cache: :hit,
        cache_serve_us: hit_debug.cache_serve_us,
        cache_key: hit_debug.cache_key
      )
    else
      []
    end
  end

  defp send_normalized_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry, headers) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        put_resp_header(conn, name, value)
      end)

    conn
    |> put_resp_content_type(entry.content_type, nil)
    |> send_body(entry.body)
  end

  @doc false
  def send_complete_body(
        conn,
        content_type,
        body,
        %CacheHeaders{} = prepared,
        %Request{} = request,
        debug,
        cache_info,
        opts
      ) do
    {:ok, disposition} = Disposition.render(request, content_type)

    conn = put_resp_headers(conn, debug_headers(debug, cache_info, opts))
    headers = merge_delivery_headers(conn, [{"content-disposition", disposition}], prepared)

    conn
    |> put_resp_headers(headers)
    |> put_resp_content_type(content_type)
    |> send_body(body)
  end

  @doc false
  def send_body(%Plug.Conn{method: "HEAD"} = conn, %ImagePipe.Cache.File{size: size}) do
    conn |> put_resp_header("content-length", Integer.to_string(size)) |> send_resp(200, "")
  end

  def send_body(conn, %ImagePipe.Cache.File{} = file) do
    conn =
      conn |> put_resp_header("content-length", Integer.to_string(file.size)) |> send_chunked(200)

    send_file_chunks(conn, file)
  end

  def send_body(conn, body), do: send_resp(conn, 200, body)

  defp send_file_chunks(conn, file) do
    Enum.reduce_while(ImagePipe.Cache.File.stream(file), conn, fn bytes, conn ->
      case chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, mark_send_processing_error(conn)}
      end
    end)
  rescue
    _exception -> mark_send_processing_error(conn)
  end

  def send_prepared_stream(
        %Plug.Conn{} = conn,
        %PreparedStream{} = prepared_stream,
        %Request{} = request,
        %CacheHeaders{} = prepared,
        opts
      ) do
    telemetry_opts = Telemetry.telemetry_opts(opts)
    {:ok, disposition} = Disposition.render(request, prepared_stream.content_type)

    prepared_stream = %{
      prepared_stream
      | headers: prepared_stream.headers ++ [{"content-disposition", disposition}]
    }

    prepared_stream = maybe_add_debug_headers(prepared_stream, conn, opts)

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

  defp debug_headers(nil, _cache_info, _opts), do: []

  defp debug_headers(%Info{} = debug, cache_info, opts) do
    if Keyword.get(opts, :debug?, false), do: Debug.Headers.render(debug, cache_info), else: []
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

  defp send_cache_error(%Plug.Conn{} = conn, error) do
    Logger.error("cache_error: #{inspect(error)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "cache error")
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

  defp maybe_add_debug_headers(%PreparedStream{debug: nil} = prepared_stream, _conn, _opts),
    do: prepared_stream

  defp maybe_add_debug_headers(%PreparedStream{debug: info} = prepared_stream, conn, opts) do
    if Keyword.get(opts, :debug?, false) do
      debug_headers =
        Debug.Headers.render(info,
          accept: accept_header(conn),
          cache: :miss,
          cache_key: prepared_stream.cache_key
        )

      %{prepared_stream | headers: prepared_stream.headers ++ debug_headers}
    else
      prepared_stream
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

  defp accept_header(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "accept") do
      [value | _] -> value
      [] -> ""
    end
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
