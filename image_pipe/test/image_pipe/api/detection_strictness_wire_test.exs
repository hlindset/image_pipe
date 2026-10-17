defmodule ImagePipe.API.DetectionStrictnessWireTest do
  # FlakyDetector is switched through :persistent_term, so tests run serially.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.DetectorFixtures.CornerObjectDetector
  alias ImagePipe.Test.DetectorFixtures.FlakyDetector
  alias ImagePipe.Test.DetectorFixtures.PartialFailureDetector
  alias ImagePipe.Test.DetectorFixtures.UnavailableDetector
  alias ImagePipe.Test.FakeDetector
  alias Vix.Vips.Image, as: VipsImage

  setup do
    on_exit(&FlakyDetector.reset/0)
  end

  describe "unknown classes" do
    test "reject before source access on every mount" do
      for required? <- [false, true],
          options <- ["crop=20,20/detect=unicorn", "crop=20,20/detect=all,unicorn:3"] do
        opts = mount(detector: CornerObjectDetector, detector_required: required?)
        response = response(options, opts)

        assert response.status == 400
        assert response.resp_body =~ "unicorn"
        refute_received :origin_fetch
      end
    end

    test "are not checked when detection is disabled" do
      opts = mount(detector: nil)
      assert response("crop=20,20/detect=unicorn", opts).status == 200
    end
  end

  describe "strict mounts" do
    test "return 503 before source access when models are missing" do
      FlakyDetector.set(:ready?, false)
      opts = observed(detector: FlakyDetector, detector_required: true)

      assert response("crop=20,20/detect=face", opts).status == 503
      refute_received :origin_fetch
      refute_received {:cache_lookup, _, _key}
    end

    test "serve detection without ready models when not strict" do
      FlakyDetector.set(:ready?, false)
      opts = mount(detector: FlakyDetector)
      assert response("crop=20,20/detect=face", opts).status == 200
    end

    test "fail the request when detection errors" do
      FlakyDetector.set(:fail?, true)
      opts = observed(detector: FlakyDetector, detector_required: true)

      assert response("w=50/h=50/fit=cover/detect=car", opts).status == 500
      refute_received {:cache_open_sink, _key, _metadata}
    end

    test "fail when any routed detector errors" do
      strict = mount(detector: PartialFailureDetector, detector_required: true)
      assert response("crop=50,50/detect=car,face", strict).status == 500
    end

    test "use attention for face-assisted crops without calling a detector that isn't ready" do
      FlakyDetector.set(:ready?, false)
      opts = observed(detector: FlakyDetector, detector_required: true)

      assisted = response("w=700/h=1400/fit=cover/anchor=smart-face", opts)
      assert get_resp_header(assisted, "cache-control") == ["no-store"]
      assert flush_cache_puts() == 0

      attention = response("w=700/h=1400/fit=cover/anchor=smart", opts)
      assert pixels(image(assisted)) == pixels(image(attention))
    end

    test "still fall back for face-assisted attention" do
      FlakyDetector.set(:fail?, true)
      opts = mount(detector: FlakyDetector, detector_required: true)
      assert response("w=50/h=50/fit=cover/anchor=smart-face", opts).status == 200
    end
  end

  describe "a content-aware crop that covers the whole image" do
    # beach.jpg is 4000×2667, so these boxes can't move.
    @whole [
      "crop=8000,8000/detect=face",
      "w=4000/h=2667/fit=cover/detect=face",
      "crop=8000,8000/anchor=smart-face"
    ]

    test "runs no detection" do
      FlakyDetector.set(:fail?, true)
      opts = mount(detector: FlakyDetector, detector_required: true)

      for options <- @whole, do: assert(response(options, opts).status == 200, options)
    end

    test "costs no detection in the cache's estimate" do
      {plug, opts} = observed(detector: FlakyDetector)

      for {options, plain} <- [
            {"crop=8000,8000/detect=face", "crop=8000,8000/anchor=center"},
            {"crop=8000,8000/anchor=smart-face", "crop=8000,8000/anchor=center/cb=two"}
          ] do
        assert response(options, {plug, opts}).status == 200
        assert_received {:cache_open_sink, _hash, %{cost_us: detected}}
        assert response(plain, {plug, opts}).status == 200
        assert_received {:cache_open_sink, _hash, %{cost_us: undetected}}
        assert detected == undetected, options
      end
    end
  end

  describe "fallback after a detection error" do
    test "is sent without storage or validator, then recovers" do
      prefix = [:detection_strictness_no_store]
      attach(prefix ++ [:http_cache, :fallback, :no_store])
      FlakyDetector.set(:fail?, true)
      opts = observed(detector: FlakyDetector, telemetry_prefix: prefix)

      degraded = response("w=700/h=700/fit=cover/detect=car", opts)

      assert get_resp_header(degraded, "cache-control") == ["no-store"]
      assert get_resp_header(degraded, "etag") == []
      assert_received {:telemetry, %{reason: :detection_failed}}
      assert flush_cache_puts() == 0

      attention = response("w=700/h=700/fit=cover/anchor=smart", opts)
      assert pixels(image(degraded)) == pixels(image(attention))

      FlakyDetector.set(:fail?, false)
      _ = flush_cache_puts()
      recovered = response("w=700/h=700/fit=cover/detect=car", opts)

      refute pixels(image(recovered)) == pixels(image(attention))
      assert [_etag] = get_resp_header(recovered, "etag")
      assert flush_cache_puts() == 1
    end

    test "applies to face-assisted attention and placeholder output" do
      FlakyDetector.set(:fail?, true)
      opts = observed(detector: FlakyDetector)

      for {path, opts} <- [
            {"/w=50/h=50/fit=cover/anchor=smart-face/format=png/src/beach.jpg", opts},
            {"/w=50/h=50/fit=cover/detect=car/output=blurhash/src/beach.jpg", opts},
            {"/w=50/h=50/fit=cover/detect=car/output=info/src/beach.jpg", opts},
            {"/crop=50,50/detect=car,face/format=png/src/beach.jpg",
             observed(detector: PartialFailureDetector)}
          ] do
        response = conn(:get, path) |> call_pipe(opts)

        assert response.status == 200
        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert get_resp_header(response, "etag") == []
        refute_received {:cache_put, _key, _body}
      end
    end

    test "stays no-store on an expiring URL with a host Cache-Control" do
      FlakyDetector.set(:fail?, true)
      expires = System.os_time(:second) + 600

      response =
        conn(:get, "/expires=#{expires}/w=50/h=50/fit=cover/detect=car/format=png/src/beach.jpg")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> call_pipe(mount(detector: FlakyDetector))

      assert response.status == 200
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "etag") == []
    end

    test "is reported on in-process results" do
      FlakyDetector.set(:fail?, true)
      config = ImagePipe.config(detector: FlakyDetector)
      bytes = File.read!("priv/static/images/beach.jpg")

      plan =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(crop: {50, 50}, detect: ["car"])
        |> ImagePipe.URL.output(format: :png)

      assert {:ok, %ImagePipe.Result{degraded?: true}} =
               ImagePipe.run(config, plan, {:binary, bytes})

      FlakyDetector.set(:fail?, false)

      assert {:ok, %ImagePipe.Result{degraded?: false}} =
               ImagePipe.run(config, plan, {:binary, bytes})
    end

    test "does not apply when the detector is unavailable or finds nothing" do
      for detector <- [UnavailableDetector, FakeDetector] do
        opts = observed(detector: detector)
        response = response("w=50/h=50/fit=cover/detect=face", opts)

        assert response.status == 200
        assert [_etag] = get_resp_header(response, "etag")
        assert_received {:cache_put, _key, _body}
      end
    end
  end

  def forward_event(_event, _measurements, metadata, pid), do: send(pid, {:telemetry, metadata})

  defp attach(event) do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, event, &__MODULE__.forward_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp flush_cache_puts(count \\ 0) do
    receive do
      {:cache_put, _key, _body} -> flush_cache_puts(count + 1)
    after
      0 -> count
    end
  end

  # A mount with an observed cache, and the options its instance runs with.
  defp observed(overrides) do
    opts = overrides |> options() |> CacheObserver.observe()
    {Caches.plug(opts), opts}
  end

  defp response(options, config),
    do: conn(:get, "/#{options}/format=png/src/beach.jpg") |> call_pipe(config)

  # Cache writes finish after the response, so wait for them before a test
  # asserts what was stored.
  defp call_pipe(conn, {plug, opts}) do
    conn = ImagePipe.Plug.call(conn, plug)
    Caches.await_writes(opts)
    conn
  end

  defp call_pipe(conn, config), do: ImagePipe.Plug.call(conn, config)

  defp image(response) do
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp pixels(image), do: VipsImage.write_to_binary(image)

  defp mount(overrides), do: overrides |> options() |> ImagePipe.Plug.init()

  defp options(overrides) do
    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            byte_identity: :strong,
            internal_cache: :enabled,
            req_options: [plug: origin()]
          ]
        ]
      ],
      http_cache: :auto,
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    ]
    |> Keyword.merge(overrides)
  end

  defp origin do
    body = File.read!("priv/static/images/beach.jpg")
    pid = self()

    fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end
  end
end
