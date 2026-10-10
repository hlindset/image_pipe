defmodule Mix.Tasks.Imgproxy.Bench do
  @shortdoc "Time image_pipe_server against imgproxy on the reference cases"
  @moduledoc """
  Times the imgproxy reference cases' paired requests against two Docker
  containers: the pinned imgproxy image the bake uses and an
  `image_pipe_server` image. Requires the `docker` CLI and a server image,
  built with `mise run server:image`.

      MIX_ENV=test mise exec -- mix imgproxy.bench [options]

  Both servers get the same CPU set, memory limit and worker count, no cache,
  no URL signatures, and the same encoder settings. Only one server runs at a
  time. `oha` drives the load from its own container on a private Docker
  network, pinned to CPUs the servers don't use.

  First each server answers every case once. A case is timed only when both
  return 200 with the same content type and dimensions. The rest are reported
  as mismatches. Then, for each server, the bench times its health endpoint as
  an HTTP baseline and every case at concurrency 1 and at the worker count,
  reading the server container's memory and CPU use from its cgroup.

  Results go to `tmp/imgproxy_bench/results.json` and an HTML report next to
  it. The run takes roughly `cases × 2 servers × (2 × duration + 1s)`.

  Options:

    * `--only` - comma-separated case ids or families (`resize`, `crop`,
      `canvas`, `orientation`, `trim`, `effects`, `watermark`, `output`).
    * `--cpus` - CPUs pinned to each server, default 4. Must leave at least
      one CPU for `oha`.
    * `--concurrency` - server worker count and the second load level,
      default `--cpus`.
    * `--memory` - memory limit per server, default `2g`.
    * `--duration` - seconds per measurement, default 3.
    * `--corpus` - a file listing extra images, one path per line, as in
      `bench/corpus.txt`. The cases that don't depend on their source's EXIF,
      alpha, colour profile or bit depth also run on each image.
    * `--server-image` - default `image_pipe_server:dev`.
    * `--server-env` - an extra `NAME=value` environment variable for the
      server container, such as `VIPS_CONCURRENCY=1`. Repeatable.
    * `--output` - results directory, default `tmp/imgproxy_bench`.
    * `--report-only` - render the HTML report from an existing
      `results.json` without running anything.

  Absolute timings depend on the host. On macOS they include the Docker VM.
  Compare the ratios between the servers, and keep results only from a
  dedicated Linux machine.

  ## Comparing server images

  `--compare` times one `image_pipe_server` image against one or more others
  instead of against imgproxy, such as a pull request against its base:

      MIX_ENV=test mise exec -- mix imgproxy.bench \\
        --compare image_pipe_server:pr --against base=image_pipe_server:base

    * `--compare` - the image to judge.
    * `--against` - `NAME=IMAGE`, an image to judge it against. Repeatable;
      each gets its own columns.
    * `--rounds` - how many times every image runs every case, default 3.

  Each round runs every image in turn, in reverse order on alternate rounds,
  so drift on the machine reaches them alike. A case is timed when every image
  returns the same status, content type and dimensions. The report gives the
  median of the rounds for each case, and for each family the ratio to each
  `--against` image with its spread across rounds. A family is marked when
  every round has it more than 10% slower or using 10% more memory.
  `summary.md` holds the family table in Markdown, for a pull request comment.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.ImgproxyBench.CompareReport
  alias ImagePipe.Test.ImgproxyBench.Report
  alias ImagePipe.Test.ImgproxyReference.Cases
  alias ImagePipe.Test.ImgproxyReference.Container

  @oha "ghcr.io/hatoo/oha:1.16.0@sha256:3ec3dbf549ea197793482d47a6324797411406bbf438c2fe8b91f244ec641a2f"
  @sources "test/support/image_pipe/test/sources"
  @family_keys [
    {"watermark", ["wm"]},
    {"trim", ["trim"]},
    {"effects", ["blur", "sharpen", "pixelate"]},
    {"orientation", ["rotate", "flip", "orient"]},
    {"canvas", ["extend", "pad", "bg"]},
    {"crop", ["crop", "region"]},
    {"output", ["format", "q", "hdr", "profile", "meta"]}
  ]
  @families ["resize" | Enum.map(@family_keys, &elem(&1, 0))]
  # Sources whose content the cases don't depend on, so the cases also make
  # sense on a corpus photo.
  @generic_sources ~w(high_freq.jpg high_freq.webp marker.png placement.png small.png)
  @max_input_pixels 100_000_000
  @max_body_bytes 100_000_000

  @switches [
    only: :string,
    cpus: :integer,
    concurrency: :integer,
    memory: :string,
    duration: :integer,
    corpus: :string,
    server_image: :string,
    server_env: :keep,
    output: :string,
    report_only: :boolean,
    compare: :string,
    against: :keep,
    rounds: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    output = opts[:output] || "tmp/imgproxy_bench"
    results_path = Path.join(output, "results.json")

    if opts[:report_only] do
      results = results_path |> File.read!() |> JSON.decode!()
      write_report!(output, results)
    else
      Mix.Task.run("app.start")
      json = opts |> bench(output) |> JSON.encode!()
      File.mkdir_p!(output)
      File.write!(results_path, json)
      write_report!(output, JSON.decode!(json))
    end
  end

  # -- Setup -----------------------------------------------------------------

  defp bench(opts, output) do
    host_cpus = String.to_integer(Container.docker!(["info", "--format", "{{.NCPU}}"]))
    cpus = opts[:cpus] || 4

    if cpus >= host_cpus do
      Mix.raise("--cpus #{cpus} leaves no CPU for oha; Docker sees #{host_cpus}")
    end

    network = "imgproxy-bench-#{System.unique_integer([:positive])}"

    settings = %{
      server_cpus: "0-#{cpus - 1}",
      oha_cpus: "#{cpus}-#{host_cpus - 1}",
      cpus: cpus,
      concurrency: opts[:concurrency] || cpus,
      memory: opts[:memory] || "2g",
      duration: opts[:duration] || 3,
      server_image: opts[:server_image] || "image_pipe_server:dev",
      server_env: Keyword.get_values(opts, :server_env),
      network: network,
      oha: "#{network}-oha",
      servers: servers(opts),
      rounds: opts[:rounds] || 3,
      progress: nil,
      work: Path.expand(Path.join(output, "work"))
    }

    File.rm_rf!(settings.work)
    sources = Path.join(settings.work, "sources")
    File.mkdir_p!(sources)
    File.cp_r!(@sources, sources)
    File.write!(Path.join(settings.work, "config.toml"), server_config(settings))

    cases =
      Cases.all()
      |> Enum.map(&Map.put(&1, :family, family(&1)))
      |> Kernel.++(corpus_cases(opts[:corpus], sources))
      |> select(opts[:only])

    Mix.shell().info(
      "#{length(cases)} case(s), about #{estimate_minutes(cases, settings)} min. " <>
        "Servers on CPUs #{settings.server_cpus}, oha on #{settings.oha_cpus}."
    )

    Container.docker!(["network", "create", settings.network])

    try do
      # One oha container serves every measurement, through `docker exec`.
      Container.docker!(
        ["run", "-d", "--name", settings.oha, "--network", settings.network] ++
          ["--cpuset-cpus", settings.oha_cpus, "--entrypoint", "sleep", @oha, "infinity"]
      )

      run_servers(cases, settings)
    after
      Container.docker(["rm", "-f", settings.oha])
      Container.docker(["network", "rm", settings.network])
    end
  end

  # Compare mode judges one ImagePipe image against others; otherwise the
  # configured image runs against imgproxy.
  defp servers(opts) do
    case opts[:compare] do
      nil ->
        nil

      image ->
        against = opts |> Keyword.get_values(:against) |> Enum.map(&against/1)
        if against == [], do: Mix.raise("--compare needs at least one --against NAME=IMAGE")
        [{"candidate", image} | against]
    end
  end

  defp against(value) do
    case String.split(value, "=", parts: 2) do
      [name, image] when name != "" and image != "" -> {name, image}
      _other -> Mix.raise("--against takes NAME=IMAGE, got #{inspect(value)}")
    end
  end

  defp run_servers(cases, %{servers: nil} = settings) do
    servers = [imgproxy_server(settings), image_pipe_server(settings)]
    {checks, timed, mismatched} = check_servers(servers, cases, settings)
    settings = %{settings | progress: progress(timed, length(servers))}

    runs =
      Map.new(servers, fn server ->
        {server.key,
         with_server(server, settings, fn info ->
           measure_server(server, timed, settings, info)
         end)}
      end)

    %{
      "environment" => environment(settings, runs),
      "cases" => Enum.map(timed, &case_result(&1, runs)),
      "baseline" => Map.new(runs, fn {key, run} -> {key, run.baseline} end),
      "mismatches" => Enum.map(mismatched, &mismatch(&1, checks))
    }
  end

  defp run_servers(cases, settings) do
    servers =
      for {key, image} <- settings.servers, do: image_pipe_server(settings, key, image)

    {checks, timed, mismatched} = check_servers(servers, cases, settings)

    settings = %{settings | progress: progress(timed, length(servers) * settings.rounds)}

    # Alternate rounds run the images in reverse order.
    rounds =
      for round <- 1..settings.rounds do
        order = if rem(round, 2) == 1, do: servers, else: Enum.reverse(servers)
        Mix.shell().info("Round #{round}/#{settings.rounds}")
        stage = "round #{round}/#{settings.rounds}, "

        Map.new(order, fn server ->
          {server.key,
           with_server(server, settings, &measure_server(server, timed, settings, &1, stage))}
        end)
      end

    [first | _] = rounds

    %{
      "mode" => "compare",
      "candidate" => "candidate",
      "against" => for({key, _image} <- tl(settings.servers), do: key),
      "environment" => environment(settings, first),
      "cases" => Enum.map(timed, &compare_result(&1, rounds)),
      "baseline" =>
        Map.new(servers, fn s -> {s.key, Enum.map(rounds, &Map.fetch!(&1, s.key).baseline)} end),
      "mismatches" => Enum.map(mismatched, &mismatch(&1, checks))
    }
  end

  defp check_servers(servers, cases, settings) do
    checks =
      Map.new(servers, fn server ->
        {server.key, with_server(server, settings, &check_all(server, cases, &1))}
      end)

    {timed, mismatched} = Enum.split_with(cases, &matches?(checks, &1))
    {checks, timed, mismatched}
  end

  defp imgproxy_server(settings) do
    %{
      key: "imgproxy",
      label: "imgproxy #{Container.version()}",
      image: Container.image(),
      health: "/health",
      path: &Container.imgproxy_path/1,
      libvips: &Container.imgproxy_libvips/1,
      args: [
        "-e",
        "IMGPROXY_LOCAL_FILESYSTEM_ROOT=/srv",
        "-e",
        "IMGPROXY_WATERMARK_PATH=/srv/alpha.png",
        "-e",
        "IMGPROXY_WORKERS=#{settings.concurrency}",
        "-e",
        "IMGPROXY_MAX_SRC_RESOLUTION=#{div(@max_input_pixels, 1_000_000)}",
        "-e",
        "IMGPROXY_MAX_SRC_FILE_SIZE=#{@max_body_bytes}",
        "-e",
        "IMGPROXY_AVIF_SPEED=8",
        "-e",
        "IMGPROXY_WEBP_EFFORT=4",
        "-v",
        "#{Path.join(settings.work, "sources")}:/srv:ro"
      ]
    }
  end

  defp image_pipe_server(settings, key \\ "image_pipe", image \\ nil) do
    image = image || settings.server_image

    %{
      key: key,
      label: Enum.join(["image_pipe_server (#{image})" | settings.server_env], " "),
      image: image,
      health: "/health/live",
      path: &Container.native_path/1,
      libvips: &Container.libvips(&1, "/usr/local/lib"),
      args:
        Enum.flat_map(settings.server_env, &["-e", &1]) ++
          [
            "--read-only",
            "--tmpfs",
            "/tmp",
            "-v",
            "#{Path.join(settings.work, "config.toml")}:/etc/image_pipe/config.toml:ro",
            "-v",
            "#{Path.join(settings.work, "sources")}:/data/images:ro"
          ]
    }
  end

  # imgproxy's AVIF speed 8 is libvips effort 1 (`9 - speed`); both default
  # to WebP effort 4. Neither caches, and neither checks signatures.
  defp server_config(settings) do
    """
    [sources.bench]
    adapter = "file"
    match = "path"
    root = "/data/images"
    root_id = "bench"

    [processing]
    auto_avif = false
    auto_webp = false
    max_input_pixels = #{@max_input_pixels}
    max_body_bytes = #{@max_body_bytes}
    avif_options.effort = 1
    webp_options.effort = 4

    [processing.watermarks.mark]
    source = "alpha.png"

    [pool]
    max_concurrency = #{settings.concurrency}
    max_queue = 4096
    queue_timeout = 120000
    processing_timeout = 120000
    """
  end

  # -- Cases -----------------------------------------------------------------

  # The first family whose option keys a case uses. An EXIF source counts as an
  # orientation option and lossy output as a format option.
  defp family(c) do
    keys = c.native |> String.split("/") |> Enum.map(&(&1 |> String.split("=") |> hd()))
    keys = if String.starts_with?(c.source, "exif"), do: ["orient" | keys], else: keys
    keys = if c.kind == :lossy, do: ["format" | keys], else: keys

    Enum.find_value(@family_keys, "resize", fn {family, prefixes} ->
      if Enum.any?(keys, &String.starts_with?(&1, prefixes)), do: family
    end)
  end

  defp corpus_cases(nil, _sources), do: []

  defp corpus_cases(list, sources) do
    images =
      list
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.map(&(&1 |> String.split() |> hd()))

    File.mkdir_p!(Path.join(sources, "corpus"))

    for {path, index} <- Enum.with_index(images, 1),
        name = "corpus/#{index}-#{Path.basename(path)}",
        :ok = File.cp!(path, Path.join(sources, name)),
        c <- Cases.all(),
        c.source in @generic_sources do
      Map.merge(c, %{id: "#{c.id}@#{index}", source: name, family: family(c)})
    end
  end

  defp select(cases, nil), do: cases

  defp select(cases, only) do
    names = String.split(only, ",", trim: true)
    selected = Enum.filter(cases, &(&1.id in names or &1.family in names))
    unknown = Enum.reject(names, &(&1 in @families or Enum.any?(cases, fn c -> c.id == &1 end)))
    if unknown != [], do: Mix.raise("Unknown case id(s) or families: #{Enum.join(unknown, ", ")}")
    selected
  end

  # The warm-up and the two `docker exec` calls add about a second a case.
  defp estimate_minutes(cases, %{servers: nil} = settings),
    do: ceil(length(cases) * 2 * (2 * settings.duration + 1) / 60)

  defp estimate_minutes(cases, settings) do
    runs = length(settings.servers) * settings.rounds
    ceil(length(cases) * runs * (2 * settings.duration + 1) / 60)
  end

  # -- Servers ---------------------------------------------------------------

  defp with_server(server, settings, fun) do
    # oha resolves the container by name, and hostnames can't hold `_`.
    name = "#{settings.network}-#{String.replace(server.key, "_", "-")}"

    Container.docker!(
      [
        "run",
        "-d",
        "--name",
        name,
        "--network",
        settings.network,
        "--cpuset-cpus",
        settings.server_cpus,
        "--memory",
        settings.memory,
        "-p",
        "127.0.0.1::8080"
      ] ++ server.args ++ [server.image]
    )

    try do
      base_url = "http://127.0.0.1:#{Container.mapped_port!(name)}"
      wait_until_ready!(name, base_url <> server.health)
      fun.(%{name: name, base_url: base_url})
    after
      Container.docker(["rm", "-f", name])
    end
  end

  defp wait_until_ready!(name, url) do
    Container.wait_until_ready!(url)
  rescue
    error in Mix.Error ->
      {logs, _} = System.cmd("docker", ["logs", "--tail", "20", name], stderr_to_stdout: true)
      Mix.raise(error.message <> "\n" <> logs)
  end

  defp check_all(server, cases, info) do
    Mix.shell().info("Checking #{server.label}")
    Map.new(cases, fn c -> {c.id, check(info.base_url <> server.path.(c))} end)
  end

  # A response the bench can't read counts as a mismatch, not a crash.
  defp check(url) do
    with {:ok, %Req.Response{status: 200, body: body} = response} <-
           Req.get(url, decode_body: false, retry: false, receive_timeout: 120_000),
         [content_type] <- Req.Response.get_header(response, "content-type"),
         {:ok, image} <- Image.open(body, access: :random) do
      %{
        "status" => 200,
        "content_type" => content_type,
        "width" => Image.width(image),
        "height" => Image.height(image)
      }
    else
      {:ok, %Req.Response{status: status}} -> %{"status" => status}
      {:error, %{__exception__: true} = exception} -> %{"status" => Exception.message(exception)}
      {:error, reason} -> %{"status" => "200 that doesn't decode: #{inspect(reason)}"}
      _headers -> %{"status" => "200 with no single content type"}
    end
  end

  defp matches?(checks, c) do
    responses = Enum.map(checks, fn {_key, results} -> Map.fetch!(results, c.id) end)
    Enum.all?(responses, &(&1["status"] == 200)) and length(Enum.uniq(responses)) == 1
  end

  defp mismatch(c, checks) do
    %{
      "id" => c.id,
      "family" => c.family,
      "source" => c.source,
      "native" => c.native,
      "imgproxy" => c.imgproxy,
      "responses" => Map.new(checks, fn {key, results} -> {key, Map.fetch!(results, c.id)} end)
    }
  end

  defp measure_server(server, cases, settings, info, stage \\ "") do
    Mix.shell().info("Timing #{server.label}")
    url = &"http://#{info.name}:8080#{&1}"
    levels = Enum.uniq([1, settings.concurrency])

    baseline = Map.new(levels, &{"#{&1}", measure(url.(server.health), &1, settings, info.name)})

    timings =
      cases
      |> Enum.with_index(1)
      |> Map.new(fn {c, index} ->
        case_url = url.(server.path.(c))
        warm_up(case_url, settings)
        timing = Map.new(levels, &{"#{&1}", measure(case_url, &1, settings, info.name)})
        report_progress(settings.progress, "#{stage}#{server.key}", index, length(cases))
        {c.id, timing}
      end)

    %{
      baseline: baseline,
      timings: timings,
      libvips: server.libvips.(info.name),
      image_id: Container.docker!(["image", "inspect", "--format", "{{.Id}}", server.image]),
      label: server.label
    }
  end

  # Counts measured cases across the run, so each progress line can say how
  # long the rest will take at the rate so far.
  defp progress(cases, runs) do
    %{
      done: :counters.new(1, []),
      total: length(cases) * runs,
      started: System.monotonic_time(:second)
    }
  end

  defp report_progress(progress, stage, index, count) do
    :counters.add(progress.done, 1, 1)

    if rem(index, 10) == 0 or index == count do
      done = :counters.get(progress.done, 1)
      elapsed = System.monotonic_time(:second) - progress.started
      left = div(elapsed * (progress.total - done), done)

      Mix.shell().info(
        "  #{stage}: #{index}/#{count} cases, #{minutes(elapsed)} elapsed, " <>
          "about #{minutes(left)} left"
      )
    end
  end

  defp minutes(seconds) when seconds < 60, do: "#{seconds}s"
  defp minutes(seconds), do: "#{div(seconds, 60)} min"

  defp warm_up(url, settings) do
    oha(["-n", "#{2 * settings.concurrency}", "-c", "#{settings.concurrency}", url], settings)
  end

  # Reads the server's cgroup: CPU time over the run, and memory sampled every
  # 200 ms while oha runs.
  defp measure(url, concurrency, settings, container) do
    cpu_before = cpu_usec(container)
    started = System.monotonic_time(:microsecond)
    sampler = Task.async(fn -> sample_memory(container, nil) end)
    load = oha(["-z", "#{settings.duration}s", "-c", "#{concurrency}", "-w", url], settings)
    elapsed = System.monotonic_time(:microsecond) - started
    send(sampler.pid, :stop)
    peak = Task.await(sampler, 30_000)
    metrics = load["metrics"]

    %{
      "requests_per_sec" => metrics["requests_per_sec"],
      "latency_ms" => metrics["latency_ms"],
      "statuses" => load["statusCodeDistribution"],
      "errors" => load["errorDistribution"],
      "peak_memory_mib" => peak,
      "mean_cpu_percent" => Float.round((cpu_usec(container) - cpu_before) / elapsed * 100, 1)
    }
  end

  defp oha(args, settings) do
    command = ["exec", settings.oha, "oha", "--no-tui", "--output-format", "json"] ++ args

    case Container.docker(command) do
      {out, 0} -> JSON.decode!(out)
      {_out, status} -> Mix.raise("oha exited with #{status}: #{List.last(args)}")
    end
  end

  defp cpu_usec(container) do
    ["exec", container, "grep", "^usage_usec ", "/sys/fs/cgroup/cpu.stat"]
    |> Container.docker!()
    |> String.split()
    |> List.last()
    |> String.to_integer()
  end

  # Memory in use as `docker stats` counts it: the cgroup's usage without
  # inactive page cache.
  defp sample_memory(container, peak) do
    receive do
      :stop -> peak
    after
      200 -> sample_memory(container, max_mib(peak, memory_mib(container)))
    end
  end

  defp memory_mib(container) do
    script =
      "cat /sys/fs/cgroup/memory.current; grep '^inactive_file ' /sys/fs/cgroup/memory.stat"

    case Container.docker(["exec", container, "sh", "-c", script]) do
      {out, 0} ->
        [current, "inactive_file", inactive] = String.split(out)
        Float.round((String.to_integer(current) - String.to_integer(inactive)) / 1_048_576, 1)

      _failed ->
        nil
    end
  end

  defp max_mib(nil, sample), do: sample
  defp max_mib(peak, nil), do: peak
  defp max_mib(peak, sample), do: max(peak, sample)

  defp case_result(c, runs) do
    %{
      "id" => c.id,
      "family" => c.family,
      "source" => c.source,
      "native" => c.native,
      "imgproxy" => c.imgproxy,
      "timings" => Map.new(runs, fn {key, run} -> {key, Map.fetch!(run.timings, c.id)} end)
    }
  end

  defp compare_result(c, rounds) do
    %{
      "id" => c.id,
      "family" => c.family,
      "source" => c.source,
      "native" => c.native,
      "rounds" =>
        rounds
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Map.new(fn key ->
          {key, Enum.map(rounds, &Map.fetch!(Map.fetch!(&1, key).timings, c.id))}
        end)
    }
  end

  defp environment(settings, runs) do
    info =
      Container.docker!([
        "info",
        "--format",
        "{{.OperatingSystem}} / {{.ServerVersion}} / {{.NCPU}} CPUs / {{.KernelVersion}}"
      ])

    {host, 0} = System.cmd("uname", ["-sm"])

    %{
      "date" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "host" => String.trim(host),
      "docker" => info,
      "server_cpus" => settings.server_cpus,
      "oha_cpus" => settings.oha_cpus,
      "concurrency" => settings.concurrency,
      "memory" => settings.memory,
      "duration_s" => settings.duration,
      "rounds" => settings.rounds,
      "oha" => @oha,
      "servers" =>
        Map.new(runs, fn {key, run} ->
          {key, %{"label" => run.label, "image_id" => run.image_id, "libvips" => run.libvips}}
        end)
    }
  end

  # -- Report ----------------------------------------------------------------

  defp write_report!(output, %{"mode" => "compare"} = results) do
    path = Path.join(output, "index.html")
    File.write!(path, CompareReport.page(results))
    File.write!(Path.join(output, "summary.md"), CompareReport.summary(results))
    Mix.shell().info("Wrote #{path} and summary.md")
  end

  defp write_report!(output, results) do
    path = Path.join(output, "index.html")
    File.write!(path, Report.page(results))
    Mix.shell().info("Wrote #{path}")
  end
end
