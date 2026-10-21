defmodule ImagePipe.Telemetry.SourceURLWireTest do
  # Attaches the default Logger, whose handler ID is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Security
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Catalog
  alias ImagePipe.Test.Caches

  @secret "zzsecretvalue"
  @presigned "https://origin.test/beach.jpg?X-Amz-Signature=#{@secret}&keep=1"
  @redacted "https://origin.test/beach.jpg?X-Amz-Signature=REDACTED&keep=1"
  @mark "https://origin.test/mark.png?x-goog-credential=#{@secret}"

  setup %{test: test} do
    prefix = [__MODULE__, test]
    test_pid = self()
    handler = {__MODULE__, test}

    events =
      Enum.uniq(Catalog.traced_events(prefix) ++ Catalog.logged_events(Catalog.groups(), prefix))

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

    Telemetry.attach_default_logger(prefix: prefix, stages: true, level: :debug)

    on_exit(fn ->
      :telemetry.detach(handler)
      Telemetry.detach_default_logger()
    end)

    options = start(prefix)
    %{prefix: prefix, options: options, instance: Caches.options(options)}
  end

  test "no field carries a presigned source's credentials", ctx do
    {:ok, enc} = Security.encrypt_source(@presigned, ctx.instance, [])
    {:ok, wm_enc} = Security.encrypt_source(@mark, ctx.instance, [])
    src64 = Base.url_encode64(@presigned, padding: false)
    wm_src64 = Base.url_encode64(@mark, padding: false)

    cases = [
      {"/w=40/src/" <> URI.encode_www_form(@presigned), 200, @redacted},
      {"/w=40/src64/" <> src64, 200, @redacted},
      {"/w=40/enc/" <> enc, 200, @redacted},
      {"/wm-src64=#{wm_src64}/w=40/-/wm-enc=#{wm_enc}/src64/" <> src64, 200, @redacted},
      {"/w=40/src/" <> URI.encode_www_form("https://origin.test/missing.jpg?sig=#{@secret}"), 404,
       "https://origin.test/missing.jpg?sig=REDACTED"}
    ]

    for {path, status, source_url} <- cases do
      {response, events, log} = request(signed(path, ctx), ctx)

      assert response.status == status, path
      refute_secret(events, log, path)

      assert {_m, %{source_url: ^source_url}} = stop(events, [:request]), path
      assert {_m, %{source_url: ^source_url}} = stop(events, [:parse]), path
      assert log =~ "source_url=#{inspect(source_url)}", path
    end

    {_response, events, log} =
      request(signed("/wm-src64=#{wm_src64}/w=40/-/wm-enc=#{wm_enc}/src64/" <> src64, ctx), ctx)

    marks = List.duplicate("https://origin.test/mark.png?x-goog-credential=REDACTED", 2)
    assert {_m, %{watermark_source_urls: ^marks}} = stop(events, [:request])
    assert log =~ "watermark_source_url=#{inspect(hd(marks))}"
  end

  test "a source with invalid UTF-8 or a line break gives one valid log line", ctx do
    for {tail, source_url} <- [
          {"%FF.jpg", "\uFFFD.jpg"},
          {"a.jpg%0A[error]GET/admin", "a.jpg%0A[error]GET/admin"}
        ] do
      {_response, events, log} = request(signed("/w=40/src/" <> tail, ctx), ctx)

      assert {_m, %{source_url: ^source_url}} = stop(events, [:request]), tail
      assert String.valid?(log)
      refute log =~ "\n[error]GET/admin"
    end
  end

  test "a request that fails before parsing has only the cut path", ctx do
    src64 = Base.url_encode64(@presigned, padding: false)

    for {path, status} <- [
          {"/sig=wrong/w=40/src64/" <> src64, 403},
          {signed("/w=40/bogus=1/src64/" <> src64, ctx), 400}
        ] do
      {response, events, log} = request(path, ctx)

      assert response.status == status, path
      refute_secret(events, log, path)
      {_m, metadata} = stop(events, [:request])
      assert metadata.path =~ ~r"/src64/REDACTED\z"
      refute Map.has_key?(metadata, :source_url)
      refute log =~ "source_url="
    end
  end

  defp request(path, ctx) do
    log =
      capture_log(fn ->
        response = conn(:get, path) |> ImagePipe.Plug.call(Caches.plug(ctx.options))
        Caches.await_writes(ctx.options)
        send(self(), {:response, response})
      end)

    assert_received {:response, response}
    {response, drain([]), log}
  end

  defp drain(events) do
    receive do
      {:event, _name, _m, _meta} = event -> drain([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp stop(events, stage) do
    Enum.find_value(events, fn {:event, name, measurements, metadata} ->
      if Enum.take(name, -(length(stage) + 1)) == stage ++ [:stop],
        do: {measurements, metadata}
    end)
  end

  defp refute_secret(events, log, path) do
    refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ @secret, path
    refute log =~ @secret, path

    for url <- [@presigned, @mark] do
      refute inspect(events, limit: :infinity, printable_limit: :infinity) =~
               Base.url_encode64(url, padding: false),
             path
    end
  end

  defp signed(path, ctx), do: "/sig=#{Security.sign(path, ctx.instance)}#{path}"

  defp start(prefix) do
    body = File.read!("priv/static/images/beach.jpg")

    origin = fn conn ->
      case conn.path_info do
        ["missing.jpg"] -> send_resp(conn, 404, "")
        _other -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
      end
    end

    Caches.start!(
      telemetry_prefix: prefix,
      keys: [String.duplicate("a1", 32)],
      source_encryption_keys: [String.duplicate("2a49", 16)],
      sources: [
        http: [
          adapter: ImagePipe.Source.HTTP,
          match: [scheme: ["https"]],
          options: [
            allowed_hosts: ["origin.test"],
            address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
            req_options: [plug: origin]
          ]
        ]
      ],
      max_input_pixels: 40_000_000
    )
  end
end
