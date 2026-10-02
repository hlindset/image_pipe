if Code.ensure_loaded?(Testcontainers) do
  defmodule Mix.Tasks.Imgproxy.Bake do
    @shortdoc "Bake imgproxy reference fixtures from a pinned container"
    @moduledoc """
    Renders each case in `ImagePipe.Test.ImgproxyReference.Cases` through a
    pinned open-source imgproxy container and writes its fixture and manifest
    entry under `test/support/image_pipe/test/imgproxy_reference/`. Requires
    Docker.

        IMGPROXY_REFERENCE=1 mise exec -- mix deps.get
        IMGPROXY_REFERENCE=1 TESTCONTAINERS_RYUK_DISABLED=true MIX_ENV=test \\
          mise exec -- mix imgproxy.bake [--only id,id]

    This task only compiles when `IMGPROXY_REFERENCE` adds testcontainers, so
    run `IMGPROXY_REFERENCE=1 MIX_ENV=test mise exec -- mix compile --force`
    first. Afterwards, run `MIX_ENV=test mise exec -- mix compile --force`
    without it, or `mix test` fails to start the absent testcontainers app.

    Without `--only` it re-bakes every case and removes orphaned fixtures. Run it
    for new cases or when upgrading the pinned imgproxy, never to make a case
    match an ImagePipe change; see the README next to the cases.
    """
    use Mix.Task
    use Boundary, top_level?: true, check: [out: false]

    import Plug.Test, only: [conn: 2]

    alias ImagePipe.Test.ImgproxyReference.Cases
    alias ImagePipe.Test.PixelSuite

    @version "v4.0.17"
    @image "darthsim/imgproxy:#{@version}@sha256:db0b4b9cd690c8b3590203dea300fb759a18c4ec2af7b37424f0bdef23ce317d"
    @base "test/support/image_pipe/test/imgproxy_reference"
    @sources "test/support/image_pipe/test/sources"
    @fixtures Path.join(@base, "fixtures")
    @manifest Path.join(@base, "manifest.exs")

    @impl Mix.Task
    def run(args) do
      {opts, _, _} = OptionParser.parse(args, strict: [only: :string])
      cases = select(Cases.all(), opts[:only])

      Mix.Task.run("app.start")
      validate_native!(cases)

      {:ok, _} = Application.ensure_all_started(:testcontainers)

      case Testcontainers.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      container =
        @image
        |> Testcontainers.Container.new()
        |> Testcontainers.Container.with_exposed_port(8080)
        |> Testcontainers.Container.with_environment("IMGPROXY_LOCAL_FILESYSTEM_ROOT", "/srv")
        # The same asset the reference test configures as the `mark` watermark.
        |> Testcontainers.Container.with_environment("IMGPROXY_WATERMARK_PATH", "/srv/alpha.png")
        |> Testcontainers.Container.with_bind_mount(Path.expand(@sources), "/srv", "ro")

      {:ok, started} = Testcontainers.start_container(container)

      try do
        base_url = "http://localhost:#{Testcontainers.Container.mapped_port(started, 8080)}"
        wait_until_ready!(base_url)
        File.mkdir_p!(@fixtures)

        baked = Map.new(cases, fn c -> {c.id, bake(c, base_url)} end)
        if opts[:only] == nil, do: remove_orphans(cases)

        write_manifest!(baked, container_libvips(started))
        Mix.shell().info("Baked #{map_size(baked)} case(s) with imgproxy #{@version}")
      after
        Testcontainers.stop_container(started.container_id)
      end
    end

    defp select(cases, nil), do: cases

    defp select(cases, only) do
      ids = String.split(only, ",", trim: true)
      selected = Enum.filter(cases, &(&1.id in ids))
      missing = ids -- Enum.map(selected, & &1.id)
      if missing != [], do: Mix.raise("Unknown case id(s): #{Enum.join(missing, ", ")}")
      selected
    end

    # A case ImagePipe can't render would bake a fixture nothing can compare
    # against, so fail before starting the container.
    defp validate_native!(cases) do
      config =
        ImagePipe.Plug.init(
          sources: [
            path: [
              adapter: ImagePipe.Source.File,
              match: :path,
              options: [root: @sources, root_id: "imgproxy-bake"]
            ]
          ],
          watermarks: %{mark: [source: "alpha.png"]}
        )

      failures =
        for c <- cases,
            response = ImagePipe.Plug.call(conn(:get, native_path(c)), config),
            response.status != 200,
            do: "  #{c.id}: #{response.status} #{native_path(c)}"

      if failures != [] do
        Mix.raise("Native requests failed before baking:\n" <> Enum.join(failures, "\n"))
      end
    end

    defp native_path(%{kind: :png} = c), do: "/#{c.native}/format=png/src/#{c.source}"
    defp native_path(%{kind: :lossy} = c), do: "/#{c.native}/src/#{c.source}"

    defp imgproxy_path(%{kind: :png} = c),
      do: "/unsafe/#{c.imgproxy}/f:png/plain/local:///#{c.source}"

    defp imgproxy_path(%{kind: :lossy} = c),
      do: "/unsafe/#{c.imgproxy}/plain/local:///#{c.source}"

    defp bake(c, base_url) do
      response = Req.get!(base_url <> imgproxy_path(c), decode_body: false, retry: false)

      if response.status != 200 do
        Mix.raise("#{c.id}: imgproxy returned #{response.status}: #{response.body}")
      end

      decoded = Image.open!(response.body, access: :random, fail_on: :error)
      [content_type] = Req.Response.get_header(response, "content-type")
      structure = PixelSuite.structure(response.body, content_type)

      case c.kind do
        :png ->
          path = Path.join(@fixtures, "#{c.id}.png")
          File.write!(path, Image.write!(decoded, :memory, suffix: ".png"))
          %{fixture_sha256: sha256(path), structure: structure}

        :lossy ->
          %{
            width: Image.width(decoded),
            height: Image.height(decoded),
            content_type: content_type,
            structure: structure
          }
      end
    end

    defp remove_orphans(cases) do
      keep = MapSet.new(cases, &"#{&1.id}.png")

      for file <- File.ls!(@fixtures), file not in keep do
        File.rm!(Path.join(@fixtures, file))
      end
    end

    defp write_manifest!(baked, libvips) do
      previous =
        if File.exists?(@manifest),
          do: @manifest |> Code.eval_file() |> elem(0),
          else: %{cases: %{}}

      cases = Map.merge(previous.cases, baked)
      ids = MapSet.new(Cases.all(), & &1.id)
      cases = Map.filter(cases, fn {id, _} -> id in ids end)

      sources =
        Cases.all()
        |> Enum.map(& &1.source)
        |> Enum.uniq()
        |> Map.new(&{&1, sha256(Path.join(@sources, &1))})

      manifest = %{
        imgproxy_image: @image,
        imgproxy_libvips: libvips,
        sources: sources,
        cases: cases
      }

      content =
        manifest
        |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
        |> Code.format_string!()

      File.write!(@manifest, [content, "\n"])
    end

    defp wait_until_ready!(base_url, attempts \\ 60)
    defp wait_until_ready!(_base_url, 0), do: Mix.raise("imgproxy container did not become ready")

    defp wait_until_ready!(base_url, attempts) do
      case Req.get(base_url <> "/health", retry: false) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        _other ->
          Process.sleep(500)
          wait_until_ready!(base_url, attempts - 1)
      end
    end

    # imgproxy exposes no libvips version over HTTP; record the bundled
    # library's ABI soname (e.g. "42.20.2") for provenance.
    defp container_libvips(started) do
      {out, 0} =
        System.cmd("docker", [
          "exec",
          started.container_id,
          "sh",
          "-c",
          "basename $(readlink -f /opt/imgproxy/lib/libvips.so.42)"
        ])

      out |> String.trim() |> String.replace_prefix("libvips.so.", "")
    end

    defp sha256(path),
      do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end
end
