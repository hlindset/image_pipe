defmodule ImagePipe.InstanceTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.DetectorFixtures.UnavailableDetector
  alias ImagePipe.Test.DetectorFixtures.WarmingDetector
  alias ImagePipe.Transform.Detector.Warmup

  @signing_key String.duplicate("a1", 32)

  setup do
    root = Path.join(System.tmp_dir!(), "instance_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    images = Path.join(root, "images")
    File.mkdir_p!(images)
    Image.new!(24, 16, color: :red) |> Image.write!(Path.join(images, "red.png"))

    sources = [
      media: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: images, root_id: "media"]
      ]
    ]

    cache_root = Path.join(root, "cache")
    bounded = [root: cache_root, max_size_bytes: 1_000_000]
    name = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")

    %{name: name, sources: sources, bounded: bounded, cache_root: cache_root}
  end

  defp start_instance(ctx, options \\ []) do
    start_supervised!(
      {ImagePipe,
       [name: ctx.name, allow_unsigned: true, sources: ctx.sources, cache: ctx.bounded] ++
         options}
    )
  end

  defp stored_bodies(root) do
    Caches.await_writes(cache: [root: root])
    Path.wildcard(Path.join(root, "**/*.body"))
  end

  defp flush_lookups do
    receive do
      {:lookup, _pool, _cache} -> flush_lookups()
    after
      0 -> :ok
    end
  end

  defp request(path, plug_options) do
    ImagePipe.Plug.call(conn(:get, path), ImagePipe.Plug.init(plug_options))
  end

  describe "direct execution" do
    test "stores in a cache started by the instance", ctx do
      start_instance(ctx)

      builder =
        ImagePipe.URL.new(ImagePipe.url_config(ctx.name))
        |> ImagePipe.URL.group(resize: [width: 8])
        |> ImagePipe.URL.output(format: :png)

      assert {:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, "red.png"})
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "per-call options keep the instance's cache", ctx do
      start_instance(ctx)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert {:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, "red.png"}, quality: 50)
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "rejects a per-call cache, even the instance's own", ctx do
      start_instance(ctx)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))
      other = Keyword.put(ctx.bounded, :root, ctx.cache_root <> "-other")

      for cache <- [ctx.bounded, other] do
        assert_raise ArgumentError, ~r/belong to the instance/, fn ->
          ImagePipe.run(ctx.name, builder, {:source, "red.png"}, cache: cache)
        end
      end
    end

    test "rejects a per-call max_remembered_originals", ctx do
      start_instance(ctx)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert_raise ArgumentError, ~r/belong to the instance/, fn ->
        ImagePipe.run(ctx.name, builder, {:source, "red.png"}, max_remembered_originals: 5)
      end
    end

    test "validate/2 checks a plan against the instance's presets", ctx do
      start_instance(ctx, presets: %{"thumb" => "w=8"})
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert ImagePipe.validate(ctx.name, ImagePipe.URL.group(builder, presets: ["thumb"])) ==
               {:ok, []}

      assert {:error, {:invalid_request, _issues}} =
               ImagePipe.validate(ctx.name, ImagePipe.URL.group(builder, presets: ["nope"]))
    end

    test "an instance name that isn't running raises", ctx do
      builder = ImagePipe.URL.new()

      for call <- [
            fn -> ImagePipe.url_config(ctx.name) end,
            fn -> ImagePipe.run(ctx.name, builder, {:source, "red.png"}) end,
            fn -> ImagePipe.validate(ctx.name, builder) end
          ] do
        assert_raise ArgumentError, ~r/not running/, call
      end
    end
  end

  describe "source records without a cache" do
    setup ctx do
      prefix = [:"instance_#{System.unique_integer([:positive])}"]

      start_supervised!(
        {ImagePipe,
         allow_unsigned: true, name: ctx.name, sources: ctx.sources, telemetry_prefix: prefix}
      )

      test = self()
      handler = {ctx.name, :records}

      :telemetry.attach_many(
        handler,
        [prefix ++ [:cache, :lookup, :start], prefix ++ [:cache, :lookup, :stop]],
        fn
          event, _measurements, %{entry: :source_record} = meta, _config ->
            send(test, {List.last(event), Map.get(meta, :pool), Map.get(meta, :cache)})

          _event, _measurements, _meta, _config ->
            :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{red: Path.join([ctx.cache_root, "..", "images", "red.png"]) |> Path.expand()}
    end

    test "a repeat request finds the file's record in memory", ctx do
      backdate(ctx.red)

      first = request("/w=8/src/red.png", instance: ctx.name)
      assert_received {:start, :memory, nil}
      assert_received {:stop, :memory, :miss}

      second = request("/w=8/src/red.png", instance: ctx.name)
      assert_received {:start, :memory, nil}
      assert_received {:stop, :memory, :hit}

      assert etag(first) == etag(second)
    end

    test "a changed file gets a new ETag", ctx do
      backdate(ctx.red)
      first = request("/w=8/src/red.png", instance: ctx.name)

      Image.new!(24, 16, color: :blue) |> Image.write!(ctx.red)
      backdate(ctx.red, 5)
      second = request("/w=8/src/red.png", instance: ctx.name)

      refute etag(first) == etag(second)
    end

    test "run/4 with options keeps the records", ctx do
      backdate(ctx.red)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert {:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, "red.png"}, quality: 50)
      assert_received {:stop, :memory, :miss}

      assert {:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, "red.png"}, quality: 50)
      assert_received {:stop, :memory, :hit}
    end
  end

  # A file changed in the current second keeps no stat evidence, so its
  # record can't be reused. Move its times into the past.
  defp backdate(path, seconds \\ 10),
    do: File.touch!(path, System.os_time(:second) - seconds)

  defp etag(conn) do
    assert [etag] = Plug.Conn.get_resp_header(conn, "etag")
    etag
  end

  describe "url_config/1" do
    test "builds URLs with the instance's presets", ctx do
      start_instance(ctx, presets: %{"thumb" => "w=8"})
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert {:ok, _path} =
               builder |> ImagePipe.URL.group(presets: ["thumb"]) |> ImagePipe.URL.url("red.png")

      assert {:error, _reason} =
               builder |> ImagePipe.URL.group(presets: ["nope"]) |> ImagePipe.URL.url("red.png")
    end
  end

  describe "Plug with instance:" do
    test "serves requests and stores in the instance's cache", ctx do
      start_instance(ctx)

      conn = request("/w=8/format=png/src/red.png", instance: ctx.name)

      assert conn.status == 200
      assert conn.resp_body |> Image.from_binary!() |> Image.width() == 8
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "serves requests without a cache whose root another node holds", ctx do
      start_instance(ctx)
      Owner.refuse(ctx.cache_root)
      on_exit(fn -> Owner.accept(ctx.cache_root) end)

      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 200
      assert stored_bodies(ctx.cache_root) == []
    end

    test "run/4 with options reads no cache whose root another node holds", ctx do
      prefix = [:"instance_#{System.unique_integer([:positive])}"]
      start_instance(ctx, telemetry_prefix: prefix)
      test = self()

      :telemetry.attach(
        ctx.name,
        prefix ++ [:cache, :lookup, :stop],
        fn _event, _measurements, meta, _config ->
          send(test, {:lookup, meta.pool, meta.cache})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ctx.name) end)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))
      assert {:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, "red.png"})
      assert [_ | _] = stored_bodies(ctx.cache_root)

      Owner.refuse(ctx.cache_root)
      on_exit(fn -> Owner.accept(ctx.cache_root) end)
      flush_lookups()

      assert {:ok, _result} =
               ImagePipe.run(ctx.name, builder, {:source, "red.png"},
                 max_input_pixels: 50_000_000
               )

      refute_received {:lookup, :output, :hit}
    end

    test "remembers at most max_remembered_originals originals", ctx do
      images = ctx.cache_root |> Path.dirname() |> Path.join("images")
      Image.new!(24, 16, color: :blue) |> Image.write!(Path.join(images, "blue.png"))

      start_supervised!(
        {ImagePipe,
         allow_unsigned: true, name: ctx.name, sources: ctx.sources, max_remembered_originals: 1}
      )

      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      for file <- ["red.png", "blue.png"],
          do: assert({:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, file}))

      assert :ets.info(Module.concat(ctx.name, ImagePipe.Cache.SourceRecords), :size) == 1
    end

    test "keeps the records of originals in memory, out of the disk cache", ctx do
      prefix = [:"instance_#{System.unique_integer([:positive])}"]
      start_instance(ctx, telemetry_prefix: prefix)
      test = self()

      :telemetry.attach(
        ctx.name,
        prefix ++ [:cache, :lookup, :stop],
        fn _event, _measurements, meta, _config ->
          send(test, {:lookup, meta.entry, meta.pool, meta.cache})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ctx.name) end)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))
      assert {:ok, _result} = ImagePipe.run(ctx.name, builder, {:source, "red.png"})

      # One stored body: the processed image, not a record of red.png.
      assert [_body] = stored_bodies(ctx.cache_root)

      sized = ImagePipe.URL.group(builder, resize: [width: 4])
      assert {:ok, _result} = ImagePipe.run(ctx.name, sized, {:source, "red.png"})
      assert_received {:lookup, :source_record, :memory, :hit}
    end

    test "serves an instance without a cache", ctx do
      start_supervised!({ImagePipe, allow_unsigned: true, name: ctx.name, sources: ctx.sources})

      assert request("/w=8/src/red.png", instance: ctx.name).status == 200
    end

    test "a stopped instance fails requests", ctx do
      start_instance(ctx)
      stop_supervised!(ctx.name)

      assert_raise ArgumentError, ~r/not running/, fn ->
        request("/w=8/src/red.png", instance: ctx.name)
      end
    end

    test "rejects an instance: that isn't a name" do
      assert_raise ArgumentError, ~r/got: nil/, fn -> ImagePipe.Plug.init(instance: nil) end

      assert_raise ArgumentError, ~r/got: "images"/, fn ->
        ImagePipe.Plug.init(instance: "images")
      end
    end

    test "rejects shared options next to instance:", ctx do
      assert_raise ArgumentError, ~r/sources/, fn ->
        ImagePipe.Plug.init(instance: ctx.name, sources: ctx.sources)
      end
    end
  end

  describe "instance options" do
    test "takes a prebuilt config: with overrides", ctx do
      config = ImagePipe.config(allow_unsigned: true, sources: ctx.sources, cache: ctx.bounded)
      start_supervised!({ImagePipe, name: ctx.name, config: config, quality: 40})

      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 200
      assert [_ | _] = stored_bodies(ctx.cache_root)
      assert ImagePipe.Config.fetch_instance!(ctx.name).options[:quality] == 40
    end

    test "takes a prebuilt config: with URL options, keeping its cache", ctx do
      config = ImagePipe.config(allow_unsigned: true, sources: ctx.sources, cache: ctx.bounded)
      start_supervised!({ImagePipe, name: ctx.name, config: config, keys: [@signing_key]})
      path = "/w=8/format=png/src/red.png"

      assert request(path, instance: ctx.name).status == 403

      signed_path = ImagePipe.URL.sign_path(path, ImagePipe.URL.config(keys: [@signing_key]))
      assert request(signed_path, instance: ctx.name).status == 200
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "remembers one original per 50 KB of the output cache, from 10,000 to 1,000,000",
         ctx do
      limit = fn options ->
        name = Module.concat(ctx.name, "L#{System.unique_integer([:positive])}")

        start_supervised!(
          {ImagePipe, [name: name, allow_unsigned: true, sources: ctx.sources] ++ options}
        )

        ImagePipe.Config.fetch_instance!(name).options[:max_remembered_originals]
      end

      big = [root: Path.join(ctx.cache_root, "big"), max_size_bytes: 5_000_000_000]

      assert limit.(cache: big) == 100_000

      assert limit.(cache: Keyword.put(ctx.bounded, :root, Path.join(ctx.cache_root, "s"))) ==
               10_000

      assert limit.([]) == 10_000

      huge = [root: Path.join(ctx.cache_root, "huge"), max_size_bytes: 1_000_000_000_000]
      assert limit.(cache: huge) == 1_000_000

      big = Keyword.put(big, :root, Path.join(ctx.cache_root, "set"))
      assert limit.(cache: big, max_remembered_originals: 7) == 7
    end

    test "a per-call override keeps the instance's limit", ctx do
      start_instance(ctx)
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert {:ok, _result} =
               ImagePipe.run(ctx.name, builder, {:source, "red.png"}, quality: 40)

      assert :ets.info(Module.concat(ctx.name, ImagePipe.Cache.SourceRecords), :size) == 1
    end

    test "invalid options raise when the child spec is built", ctx do
      assert_raise ArgumentError, fn ->
        ImagePipe.child_spec(
          allow_unsigned: true,
          name: ctx.name,
          sources: ctx.sources,
          quality: 0
        )
      end
    end
  end

  describe "processing pool" do
    defp instance_pool(name),
      do: ImagePipe.Config.fetch_instance!(name).options[:processing_pool]

    defp hold_slot(pool) do
      test = self()

      Task.start_link(fn ->
        ImagePipe.ProcessingPool.run(
          pool,
          fn ->
            send(test, {:holding, self()})
            receive(do: (:release -> :ok))
          end,
          []
        )
      end)

      assert_receive {:holding, holder}
      holder
    end

    test "an instance starts one with a slot per online scheduler", ctx do
      start_instance(ctx)
      pool = instance_pool(ctx.name)

      assert %{active: 0, queued: 0} = ImagePipe.ProcessingPool.stats(pool)
      assert :sys.get_state(pool).limits.max_concurrency == System.schedulers_online()
      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 200
    end

    test "requests and run/4 share the instance's pool and its limits", ctx do
      start_instance(ctx, pool: [max_concurrency: 1, max_queue: 0])
      holder = hold_slot(instance_pool(ctx.name))
      builder = ImagePipe.URL.new(ImagePipe.url_config(ctx.name))

      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 503

      assert ImagePipe.run(ctx.name, builder, {:source, "red.png"}) ==
               {:error, {:processing, :overloaded}}

      send(holder, :release)
      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 200
    end

    test "pool: false starts none", ctx do
      start_instance(ctx, pool: false)

      assert instance_pool(ctx.name) == nil
      refute List.keymember?(Supervisor.which_children(ctx.name), ImagePipe.ProcessingPool, 0)
      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 200
    end

    test "a named processing_pool is used instead", ctx do
      external = Module.concat(ctx.name, External)

      start_supervised!(
        {ImagePipe.ProcessingPool, name: external, max_concurrency: 1, max_queue: 0}
      )

      for options <- [[processing_pool: external], [processing_pool: external, pool: false]] do
        start_instance(ctx, options)

        assert instance_pool(ctx.name) == external
        refute List.keymember?(Supervisor.which_children(ctx.name), ImagePipe.ProcessingPool, 0)
        holder = hold_slot(external)
        assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 503
        send(holder, :release)
        stop_supervised!(ctx.name)
      end
    end

    test "rejects invalid pool options, and pool options with a named processing_pool", ctx do
      for options <- [
            [pool: [max_concurrency: 0]],
            [pool: [name: Other]],
            [pool: :yes],
            [processing_pool: Other, pool: [max_concurrency: 2]]
          ] do
        assert_raise ArgumentError, ~r/pool/, fn ->
          ImagePipe.child_spec([name: ctx.name, sources: ctx.sources] ++ options)
        end
      end
    end
  end

  describe "detector warmup" do
    setup do
      Process.register(self(), WarmingDetector)
      on_exit(&WarmingDetector.reset/0)
    end

    test "warms the instance's detector, so a strict mount serves detection", ctx do
      start_instance(ctx, detector: WarmingDetector, detector_required: true)

      assert_receive {:warmed, :all}
      assert request("/crop=8,8/detect=face/src/red.png", instance: ctx.name).status == 200
    end

    test "warms only the configured classes", ctx do
      start_instance(ctx, detector: WarmingDetector, detector_warmup: ["face"])
      assert_receive {:warmed, ["face"]}
    end

    test "starts no warmup when turned off or the detector is unavailable", ctx do
      for options <- [
            [detector: WarmingDetector, detector_warmup: false],
            [detector: UnavailableDetector],
            [detector: nil]
          ] do
        start_instance(ctx, options)
        children = Supervisor.which_children(ctx.name)
        refute List.keymember?(children, Warmup, 0)
        stop_supervised!(ctx.name)
      end
    end

    test "rejects an invalid detector_warmup", ctx do
      for warmup <- ["face", ["fcae"]] do
        assert_raise ArgumentError, ~r/detector_warmup/, fn ->
          ImagePipe.child_spec(
            allow_unsigned: true,
            name: ctx.name,
            detector: WarmingDetector,
            detector_warmup: warmup
          )
        end
      end
    end
  end

  describe "inline configuration" do
    test "ImagePipe.run/4 rejects a config with a cache", ctx do
      config = ImagePipe.config(allow_unsigned: true, sources: ctx.sources, cache: ctx.bounded)
      builder = ImagePipe.URL.new(ImagePipe.url_config(config))

      assert_raise ArgumentError, ~r/ImagePipe instance/, fn ->
        ImagePipe.run(config, builder, {:source, "red.png"})
      end
    end

    test "ImagePipe.run/4 rejects max_remembered_originals", ctx do
      config =
        ImagePipe.config(allow_unsigned: true, sources: ctx.sources, max_remembered_originals: 5)

      builder = ImagePipe.URL.new(ImagePipe.url_config(config))

      assert_raise ArgumentError, ~r/ImagePipe instance/, fn ->
        ImagePipe.run(config, builder, {:source, "red.png"})
      end
    end

    test "Plug.init/1 rejects a cache, even one an instance runs", ctx do
      start_instance(ctx)

      assert_raise ArgumentError, ~r/ImagePipe instance/, fn ->
        ImagePipe.Plug.init(sources: ctx.sources, cache: ctx.bounded)
      end
    end
  end
end
