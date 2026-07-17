if Code.ensure_loaded?(Testcontainers) do
  defmodule Mix.Tasks.Imgproxy.GenFixtures do
    @shortdoc "Generate imgproxy differential reference fixtures from a pinned container"
    @moduledoc """
    Spins up a pinned `darthsim/imgproxy` via testcontainers, transforms the
    committed sources for every constellation, and writes committed PNG fixtures,
    `manifest.exs`, and `REPORT.md`. Requires Docker.

        MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures
    """
    use Mix.Task
    use Boundary, top_level?: true, check: [out: false]

    import Plug.Test, only: [conn: 2]

    alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Harness, Manifest}

    @image "darthsim/imgproxy@sha256:9ed8f87b34d55c7844951ff65bcf6605de54ba6670f64951c7215f9b125a482e"
    @base "test/support/image_pipe/test/imgproxy_differential"
    @sources_dir "#{@base}/sources"
    @fixtures_dir "#{@base}/fixtures"
    @manifest_path "#{@base}/manifest.exs"
    @report_path "#{@base}/REPORT.md"

    @impl Mix.Task
    def run(_args) do
      {:ok, _} = Application.ensure_all_started(:image_pipe)
      {:ok, _} = Application.ensure_all_started(:req)

      # Fail fast: a constellation that doesn't render a 200 must abort before the
      # (expensive) container start, not after baking a wrong/missing fixture.
      validate_renders!()

      # Start testcontainers' app deps (hackney/tesla) AND its GenServer (which the
      # app does not auto-start).
      {:ok, _} = Application.ensure_all_started(:testcontainers)

      case Testcontainers.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      File.mkdir_p!(@fixtures_dir)
      # Clear stale fixtures so a removed/renamed constellation can't leave an
      # orphan PNG behind (the run rewrites every current transform-group fixture).
      @fixtures_dir |> Path.join("*.png") |> Path.wildcard() |> Enum.each(&File.rm!/1)

      container =
        Testcontainers.Container.new(@image)
        |> Testcontainers.Container.with_exposed_port(8080)
        |> Testcontainers.Container.with_environment("IMGPROXY_LOCAL_FILESYSTEM_ROOT", "/srv")
        # Honour URL security options (`mrd`, `msr`, `msfs`, `maf`, `mafr`), which imgproxy
        # gates behind this flag (apply.go IsSecurityOptionsAllowed). A no-op for any
        # constellation that doesn't use one; required so quarantine-as-spec cases for
        # those still-unimplemented options can bake their imgproxy fixture (e.g. `mrd`).
        |> Testcontainers.Container.with_environment("IMGPROXY_ALLOW_SECURITY_OPTIONS", "true")
        |> Testcontainers.Container.with_bind_mount(Path.expand(@sources_dir), "/srv", "ro")

      {:ok, started} = Testcontainers.start_container(container)
      port = Testcontainers.Container.mapped_port(started, 8080)
      base_url = "http://localhost:#{port}"

      wait_until_ready!(base_url)

      imgproxy_libvips = container_libvips(started)
      pipe_libvips = Vix.Vips.version()

      Mix.shell().info(
        "imgproxy libvips #{imgproxy_libvips} (.so ABI soname); " <>
          "ImagePipe libvips #{pipe_libvips} (release) — different schemes, recorded for provenance."
      )

      source_hashes =
        Constellations.source_files()
        |> Map.values()
        |> Map.new(fn f -> {f, Manifest.file_sha256(Path.join(@sources_dir, f))} end)

      entries =
        Constellations.all()
        |> Map.new(fn c -> {c.id, generate_entry(c, base_url)} end)

      manifest = %{
        imgproxy_digest: @image |> String.split("@") |> List.last(),
        imgproxy_libvips: imgproxy_libvips,
        pipe_libvips_at_gen: pipe_libvips,
        sources: source_hashes,
        entries: entries
      }

      Manifest.write!(@manifest_path, manifest)
      write_report!(manifest)
      Mix.shell().info("Wrote #{map_size(entries)} fixtures + manifest + report under #{@base}")
    end

    # Render every constellation's path through the dialect before baking, so a
    # typo'd or unsupported option aborts the run (with the offending ids) instead of
    # spinning the container and producing a wrong/absent fixture. Quarantined
    # (`:triage`) cases are skipped: a known dialect gap (a combo imgproxy accepts but
    # ImagePipe's dialect does not yet) can sit in the suite, tracked, without blocking
    # the bake — its fixture still bakes from imgproxy, and the conformance lane excludes
    # it until the `:triage` is dropped.
    defp validate_renders! do
      {plug, plug_opts} = Harness.plug_opts()

      failures =
        Constellations.all()
        |> Enum.reject(& &1[:triage])
        |> Enum.flat_map(fn c ->
          conn = plug.call(conn(:get, Constellations.imgproxy_path(c)), plug_opts)
          if conn.status == 200, do: [], else: [{c.id, conn.status}]
        end)

      unless failures == [] do
        detail = Enum.map_join(failures, "\n", fn {id, status} -> "  #{id}: #{status}" end)

        Mix.raise(
          "gen_fixtures: #{length(failures)} constellation(s) failed to render a 200 before bake:\n#{detail}"
        )
      end
    end

    defp generate_entry(c, base_url) do
      url = base_url <> Constellations.imgproxy_path(c)
      %Req.Response{status: 200, body: body} = resp = Req.get!(url, decode_body: false)
      content_type = resp |> Req.Response.get_header("content-type") |> List.first()
      decoded = Image.open!(body, access: :random, fail_on: :error)

      authored = Manifest.authored_sha256(c)

      case c.group do
        :transform ->
          filename = "#{c.id}.png"
          png = Image.write!(decoded, :memory, suffix: ".png")
          File.write!(Path.join(@fixtures_dir, filename), png)

          %{
            kind: :transform,
            authored_sha256: authored,
            fixture_filename: filename,
            fixture_sha256: Manifest.file_sha256(Path.join(@fixtures_dir, filename))
          }

        :lossy ->
          %{
            kind: :lossy,
            authored_sha256: authored,
            width: Image.width(decoded),
            height: Image.height(decoded),
            content_type: content_type
          }
      end
    end

    defp wait_until_ready!(base_url, attempts \\ 60)

    defp wait_until_ready!(_base_url, 0), do: Mix.raise("imgproxy container did not become ready")

    defp wait_until_ready!(base_url, attempts) do
      case Req.get(base_url <> "/health", retry: false) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        _ ->
          Process.sleep(500)
          wait_until_ready!(base_url, attempts - 1)
      end
    end

    # imgproxy exposes no libvips version over HTTP, and the darthsim image has no
    # `vips` CLI — read the bundled .so realname (e.g. "libvips.so.42.20.2") and
    # record its ABI soname ("42.20.2") as the provenance identifier.
    defp container_libvips(started) do
      {out, 0} =
        System.cmd("docker", [
          "exec",
          started.container_id,
          "sh",
          "-c",
          "readlink -f /opt/imgproxy/lib/libvips.so.42 | xargs basename"
        ])

      out |> String.trim() |> String.replace_prefix("libvips.so.", "")
    end

    defp write_report!(manifest) do
      lines =
        manifest.entries
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map(fn {id, e} -> "- `#{id}` — #{e.kind}" end)

      body = """
      # imgproxy differential conformance — generation report

      - imgproxy digest: `#{manifest.imgproxy_digest}`
      - imgproxy libvips (.so ABI soname): `#{manifest.imgproxy_libvips}`
      - ImagePipe libvips at generation (release): `#{manifest.pipe_libvips_at_gen}`

      ## Constellations

      #{Enum.join(lines, "\n")}
      """

      File.write!(@report_path, body)
    end
  end
end
