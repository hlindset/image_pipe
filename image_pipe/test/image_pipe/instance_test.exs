defmodule ImagePipe.InstanceTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Cache.FileSystem
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
    bounded = [root: cache_root, max_size_bytes: 1_000_000, node_id: "test"]
    name = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")

    %{name: name, sources: sources, bounded: bounded, cache_root: cache_root}
  end

  defp start_instance(ctx, options \\ []) do
    start_supervised!(
      {ImagePipe,
       [name: ctx.name, sources: ctx.sources, cache: {FileSystem, ctx.bounded}] ++ options}
    )
  end

  defp stored_bodies(root), do: Path.wildcard(Path.join(root, "**/*.body"))

  defp request(path, plug_options) do
    ImagePipe.Plug.call(conn(:get, path), ImagePipe.Plug.init(plug_options))
  end

  describe "direct execution" do
    test "stores in a bounded cache started by the instance", ctx do
      start_instance(ctx)
      config = ImagePipe.config!(ctx.name)

      builder =
        ImagePipe.URL.new(ImagePipe.url_config(config))
        |> ImagePipe.URL.group(resize: [width: 8])
        |> ImagePipe.URL.output(format: :png)

      assert {:ok, _result} = ImagePipe.run(config, builder, {:source, "red.png"})
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "per-call options keep the instance's cache", ctx do
      start_instance(ctx)
      config = ImagePipe.config!(ctx.name)
      builder = ImagePipe.URL.new(ImagePipe.url_config(config))

      assert {:ok, _result} = ImagePipe.run(config, builder, {:source, "red.png"}, quality: 50)
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "per-call caches the instance already runs, or that need no processes", ctx do
      start_instance(ctx)
      config = ImagePipe.config!(ctx.name)
      builder = ImagePipe.URL.new(ImagePipe.url_config(config))
      unbounded = {FileSystem, root: ctx.cache_root <> "-unbounded"}

      for cache <- [{FileSystem, ctx.bounded}, unbounded] do
        assert {:ok, _result} =
                 ImagePipe.run(config, builder, {:source, "red.png"}, cache: cache)
      end
    end

    test "rejects a per-call cache that needs processes", ctx do
      start_instance(ctx)
      config = ImagePipe.config!(ctx.name)
      builder = ImagePipe.URL.new(ImagePipe.url_config(config))
      other = Keyword.put(ctx.bounded, :root, ctx.cache_root <> "-other")

      assert_raise ArgumentError, ~r/ImagePipe instance/, fn ->
        ImagePipe.run(config, builder, {:source, "red.png"}, cache: {FileSystem, other})
      end
    end

    test "config!/1 raises for an instance that isn't running", ctx do
      assert_raise ArgumentError, ~r/not running/, fn -> ImagePipe.config!(ctx.name) end
    end
  end

  describe "Plug with instance:" do
    test "serves requests and stores in the instance's bounded cache", ctx do
      start_instance(ctx)

      conn = request("/w=8/format=png/src/red.png", instance: ctx.name)

      assert conn.status == 200
      assert conn.resp_body |> Image.from_binary!() |> Image.width() == 8
      assert [_ | _] = stored_bodies(ctx.cache_root)
    end

    test "serves an instance without a cache", ctx do
      start_supervised!({ImagePipe, name: ctx.name, sources: ctx.sources})

      assert request("/w=8/src/red.png", instance: ctx.name).status == 200
    end

    test "mount: checks URLs with the instance's named mount", ctx do
      start_instance(ctx, mounts: [signed: [keys: [@signing_key]]])
      path = "/w=8/src/red.png"

      assert request(path, instance: ctx.name).status == 200
      assert request(path, instance: ctx.name, mount: :signed).status == 403

      signed_path = ImagePipe.URL.sign_path(path, ImagePipe.URL.config(keys: [@signing_key]))
      assert request(signed_path, instance: ctx.name, mount: :signed).status == 200
    end

    test "a named mount applies its URL options on top of the instance's", ctx do
      start_instance(ctx,
        keys: [@signing_key],
        mounts: [cdn: [base_url: "https://cdn.example.com"], open: [keys: []]]
      )

      path = "/w=8/src/red.png"

      assert request(path, instance: ctx.name).status == 403
      assert request(path, instance: ctx.name, mount: :cdn).status == 403
      assert request(path, instance: ctx.name, mount: :open).status == 200
    end

    test "an unknown mount: name fails the request", ctx do
      start_instance(ctx)

      assert_raise ArgumentError, ~r/:missing/, fn ->
        request("/w=8/src/red.png", instance: ctx.name, mount: :missing)
      end
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
      config = ImagePipe.config(sources: ctx.sources, cache: {FileSystem, ctx.bounded})
      start_supervised!({ImagePipe, name: ctx.name, config: config, quality: 40})

      assert request("/w=8/format=png/src/red.png", instance: ctx.name).status == 200
      assert [_ | _] = stored_bodies(ctx.cache_root)
      assert ImagePipe.config!(ctx.name).options[:quality] == 40
    end

    test "invalid options raise when the child spec is built", ctx do
      assert_raise ArgumentError, fn ->
        ImagePipe.child_spec(name: ctx.name, sources: ctx.sources, quality: 0)
      end
    end

    test "rejects mounts: entries with options other than URL options", ctx do
      for mounts <- [
            [signed: ImagePipe.URL.config(keys: [@signing_key])],
            [signed: [quality: 50]],
            [signed: [validate_against: []]]
          ] do
        assert_raise ArgumentError, ~r/mounts/, fn ->
          ImagePipe.child_spec(name: ctx.name, sources: ctx.sources, mounts: mounts)
        end
      end
    end

    test "invalid URL options in a mount raise and name the mount", ctx do
      for {mount_options, detail} <- [
            {[encrypt_source: true], "encrypt_source"},
            {[keyz: []], "keyz"}
          ] do
        error =
          assert_raise ArgumentError, fn ->
            ImagePipe.child_spec(
              name: ctx.name,
              sources: ctx.sources,
              mounts: [open: [], signed: mount_options]
            )
          end

        assert error.message =~ "mounts"
        assert error.message =~ "signed"
        assert error.message =~ detail
      end
    end

    test "rejects duplicate and nil mount names", ctx do
      for mounts <- [[signed: [], signed: []], [nil: []]] do
        assert_raise ArgumentError, ~r/mounts/, fn ->
          ImagePipe.child_spec(name: ctx.name, sources: ctx.sources, mounts: mounts)
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
          ImagePipe.child_spec(name: ctx.name, detector: WarmingDetector, detector_warmup: warmup)
        end
      end
    end
  end

  describe "inline configuration" do
    test "ImagePipe.run/4 rejects a config whose cache needs processes", ctx do
      config = ImagePipe.config(sources: ctx.sources, cache: {FileSystem, ctx.bounded})
      builder = ImagePipe.URL.new(ImagePipe.url_config(config))

      assert_raise ArgumentError, ~r/ImagePipe instance/, fn ->
        ImagePipe.run(config, builder, {:source, "red.png"})
      end
    end

    test "Plug.init/1 rejects a bounded input cache", ctx do
      assert_raise ArgumentError, ~r/ImagePipe instance/, fn ->
        ImagePipe.Plug.init(sources: ctx.sources, input_cache: {FileSystem, ctx.bounded})
      end
    end
  end
end
