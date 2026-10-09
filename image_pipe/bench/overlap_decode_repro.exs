# Diagnostic reproduction of image_plug-e4a.15.7, not a latency benchmark.
# mise exec -- mix run --preload-modules bench/overlap_decode_repro.exs auto|paced|spool|burst [REQUESTS] [IMAGE]
# paced/spool use identical transfers; only paced declares Content-Length.
Code.require_file("support/overlap_decode_origin.exs", __DIR__)

defmodule OverlapDecodeRepro do
  alias ImagePipe.Execution.SourceCache
  alias ImagePipe.Source.Download
  alias Vix.Vips.Image, as: VipsImage

  def run([mode | args]) when mode in ["auto", "paced", "spool", "burst"] do
    count = args |> Enum.at(0, "300") |> String.to_integer()
    path = Enum.at(args, 1, "priv/static/images/waterfall.jpg")
    body = File.read!(path)
    root = Path.join(System.tmp_dir!(), "overlap-decode-#{System.unique_integer([:positive])}")
    prefix = [:overlap_decode_repro]
    events = :ets.new(:overlap_decode_events, [:public, :bag])

    {:ok, origin} =
      Bandit.start_link(
        plug: {OverlapDecodeOrigin, body: body, mode: mode},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(origin)
    config = configuration(root, port, prefix)
    mount = ImagePipe.Plug.init(config: config)

    builder =
      ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: 300])
      |> ImagePipe.URL.output(format: :webp)

    {:ok, reference} = ImagePipe.run(config, builder, {:binary, body})
    expected_pixels = pixels(reference.data)
    expected_digest = :crypto.hash(:sha256, body)
    stages = [[:source, :stage], [:source, :fetch_decode], [:transform, :materialize]]

    :ok =
      :telemetry.attach_many(
        __MODULE__,
        Enum.flat_map(stages, fn stage ->
          Enum.map([:start, :stop], &(prefix ++ stage ++ [&1]))
        end),
        &capture/4,
        events
      )

    {:ok, tracer} =
      Task.Supervisor.start_child(ImagePipe.ProcessingPool.Tasks, fn -> trace(events, %{}) end)

    enable_trace(tracer)

    IO.puts(
      JSON.encode!(%{
        mode: mode,
        requests: count,
        input_bytes: byte_size(body),
        input_sha256: Base.encode16(expected_digest, case: :lower),
        elixir: System.version(),
        otp: List.to_string(:erlang.system_info(:otp_release)),
        vips: Vix.Vips.version(),
        vips_concurrency: Vix.Vips.concurrency_get(),
        schedulers: :erlang.system_info(:schedulers_online)
      })
    )

    started = System.monotonic_time(:microsecond)

    try do
      result =
        Enum.reduce(1..count, %{failures: 0, overlaps: 0, staged: 0, read: 0}, fn index, totals ->
          :ets.delete_all_objects(events)

          response =
            Plug.Test.conn(:get, "/w=300/format=webp/src/image.jpg") |> ImagePipe.Plug.call(mount)

          drain_sent()
          synchronize(tracer)
          captured = :ets.tab2list(events)
          overlapped? = early_decode?(captured, prefix)
          staged? = Enum.any?(captured, &match?({:staged, {_, ^expected_digest}}, &1))
          read? = Enum.any?(captured, &match?({:read, {_, ^expected_digest}}, &1))

          valid? =
            response.status == 200 and pixels(response.resp_body) == expected_pixels and staged? and
              (not overlapped? or read?)

          totals = %{
            failures: totals.failures + number(not valid?),
            overlaps: totals.overlaps + number(overlapped?),
            staged: totals.staged + number(staged?),
            read: totals.read + number(read?)
          }

          case valid? do
            false ->
              IO.inspect(%{request: index, status: response.status, events: captured},
                label: "failure",
                limit: :infinity
              )

            true ->
              :ok
          end

          if rem(index, 25) == 0, do: IO.puts(JSON.encode!(Map.put(totals, :completed, index)))
          totals
        end)

      IO.puts(
        JSON.encode!(
          Map.merge(result, %{
            mode: mode,
            requests: count,
            total_ms: (System.monotonic_time(:microsecond) - started) / 1000
          })
        )
      )

      result.failures
    after
      :erlang.trace(:all, false, [:call])

      Enum.each(
        [{Download, :read, 3}, {SourceCache, :stage, 5}, {VipsImage, :copy_memory, 1}],
        &:erlang.trace_pattern(&1, false, [:local])
      )

      send(tracer, :stop)
      :telemetry.detach(__MODULE__)
      Supervisor.stop(origin)
      File.rm_rf!(root)
      :ets.delete(events)
    end
  end

  defp configuration(root, port, prefix) do
    ImagePipe.config(
      telemetry_prefix: prefix,
      max_body_bytes: 20_000_000,
      max_input_pixels: 60_000_000,
      sources: [
        path: [
          adapter: ImagePipe.Source.HTTP,
          match: :path,
          options: [
            base_url: "http://127.0.0.1:#{port}",
            address_policy: [allow_loopback: true],
            address_resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
          ]
        ]
      ],
      cache: [root: Path.join(root, "output")],
      input_cache: [root: Path.join(root, "input")]
    )
  end

  def capture(event, measurements, meta, events),
    do:
      :ets.insert(
        events,
        {:event, event, measurements, meta, System.monotonic_time(:microsecond)}
      )

  defp enable_trace(tracer) do
    Enum.each(
      [{Download, :read, 3}, {SourceCache, :stage, 5}, {VipsImage, :copy_memory, 1}],
      fn target ->
        {module, _, _} = target
        Code.ensure_loaded!(module)
        :erlang.trace_pattern(target, [{:_, [], [{:return_trace}]}], [:local])
      end
    )

    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
  end

  defp trace(events, readers) do
    receive do
      {:trace, pid, :return_from, {Download, :read, 3}, {[bytes], {_io, offset}}} ->
        {hash, _offset} = Map.get(readers, pid, {:crypto.hash_init(:sha256), 0})
        hash = :crypto.hash_update(hash, bytes)
        trace(events, Map.put(readers, pid, {hash, offset}))

      {:trace, _pid, :return_from, {SourceCache, :stage, 5}, {:ok, acquisition}} ->
        :ets.insert(events, {:staged, {acquisition.source_bytes, acquisition.source_sha256}})
        trace(events, readers)

      {:trace, pid, :return_from, {VipsImage, :copy_memory, 1}, {:error, reason}} ->
        :ets.insert(events, {:native_error, {pid, reason}})
        trace(events, readers)

      {:sync, owner, ref} ->
        Enum.each(readers, fn {_pid, {hash, bytes}} ->
          :ets.insert(events, {:read, {bytes, :crypto.hash_final(hash)}})
        end)

        send(owner, {:synced, ref})
        trace(events, %{})

      :stop ->
        :ok

      _trace ->
        trace(events, readers)
    end
  end

  defp synchronize(tracer) do
    ref = :erlang.trace_delivered(:all)
    receive do: ({:trace_delivered, :all, ^ref} -> :ok)
    send(tracer, {:sync, self(), ref})
    receive do: ({:synced, ^ref} -> :ok)
  end

  defp early_decode?(events, prefix) do
    decode = event_at(events, prefix ++ [:source, :fetch_decode, :start])
    stage = event_at(events, prefix ++ [:source, :stage, :stop])

    case {decode, stage} do
      {decode, stage} when is_integer(decode) and is_integer(stage) -> decode < stage
      _missing -> false
    end
  end

  defp event_at(events, name) do
    Enum.find_value(events, fn
      {:event, ^name, _measurements, _meta, at} -> at
      _other -> nil
    end)
  end

  defp pixels(bytes) do
    {:ok, image} = Image.from_binary(bytes)
    {:ok, pixels} = VipsImage.write_to_binary(image)
    :crypto.hash(:sha256, pixels)
  end

  defp number(true), do: 1
  defp number(false), do: 0

  defp drain_sent do
    receive do
      {:plug_conn, :sent} -> drain_sent()
      {ref, {_status, _headers, _body}} when is_reference(ref) -> drain_sent()
    after
      0 -> :ok
    end
  end
end

case OverlapDecodeRepro.run(System.argv()) do
  0 -> :ok
  _failures -> System.halt(1)
end
