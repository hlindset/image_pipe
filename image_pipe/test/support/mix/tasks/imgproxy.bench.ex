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

  First each server answers every case once, then three more times to time it.
  A case is timed only when both return 200 with the same content type and
  dimensions. The rest are reported
  as mismatches. Then, for each server, the bench times its health endpoint as
  an HTTP baseline and every case at concurrency 1 and at the worker count,
  reading the server container's memory and CPU use from its cgroup.

  Results go to `tmp/imgproxy_bench/results.json` and an HTML report next to
  it. The run takes roughly `cases × 2 servers × (2 × duration + 1s)`, more
  when slow cases measure for longer.

  Options:

    * `--only` - comma-separated case ids or families (`resize`, `crop`,
      `canvas`, `orientation`, `trim`, `effects`, `watermark`, `output`, and
      with `--compare`, `decode`, `colour`, `autoquality`, `placeholder`,
      `cache`, `concurrency`), or `perf` for 34 reference cases that cover
      every family and kind of source. With `--compare`, `perf` adds the 13
      `ImagePipe.Test.Perf.Cases` every `perf` pull request times and the
      `burst_same_wide`, `burst_grid` and two `burst_overload` cases, and
      `nightly` all 29 of them and the 8 `concurrency` cases.
    * `--cpus` - CPUs pinned to each server, default 4. Must leave at least
      one CPU for `oha`.
    * `--concurrency` - server worker count and the second load level,
      default `--cpus`.
    * `--memory` - memory limit per server, default `2g`.
    * `--duration` - seconds per measurement, default 3. A slower case measures
      long enough for about 15 sequential requests, up to 10 seconds, the same
      on every server.
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

  It also times `ImagePipe.Test.Perf.Cases`, requests imgproxy has no
  equivalent for on photo-sized sources, after the candidate image makes the
  photo variants they read.

  The `cache` family runs on a second container per image, whose
  configuration adds an output cache and an `origin` HTTP
  source that reads the bench's sources from an `nginx` container on the
  same network. Every other case runs without a cache, as above.

  The `concurrency` family isn't timed by oha. Its `nightly` cases send
  `--concurrency` requests at once for a new original, which the origin sends
  at about 512 KiB/s, so they overlap its download. In the `perf` set,
  `burst_same_wide` does the same with 100 requests, and the `burst_grid` and
  `burst_overload` cases send many requests at once, each for a new original
  sent at full rate. The `burst_overload` cases send more
  than the pool takes, with the server's default queue settings, and accept
  `503`. It runs three such bursts per image and round, each in a container
  with the caches the case names, and records the time to the last
  response, the downloads the origin served, the generations the server's
  stage log shows, the cache writes it logs as dropped, the requests
  answered `503`, and how long they waited for it. The counts barely vary
  between runs, so the report marks any difference in them.

    * `--compare` - the image to judge.
    * `--against` - `NAME=IMAGE`, an image to judge it against. Repeatable;
      each gets its own columns.
    * `--rounds` - how many times every image runs every case, default 4.
      An even count gives every image the first slot equally often.
    * `--describe` - `NAME=TEXT`, what an image is, such as "this pull request
      at `e9f7670`", shown in the report in place of its image name. Name the
      `--compare` image `candidate`. Repeatable.
    * `--shard` - `I/N`, to split the rounds across N machines: this run
      does rounds I, I + N, I + 2N and so on of `--rounds`, each in the
      image order that round has in a whole run. Every shard must get the
      same options and images.
    * `--merge` - a shard's output directory. Repeatable. Merges the shards'
      `results.json` into `--output` and writes the report there, without
      running anything.

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
  alias ImagePipe.Test.ImgproxyBench.Merge
  alias ImagePipe.Test.ImgproxyBench.Report
  alias ImagePipe.Test.ImgproxyReference.Cases
  alias ImagePipe.Test.ImgproxyReference.Container
  alias ImagePipe.Test.Perf.Cases, as: PerfCases

  @oha "ghcr.io/hatoo/oha:1.16.0@sha256:3ec3dbf549ea197793482d47a6324797411406bbf438c2fe8b91f244ec641a2f"
  @nginx "nginx:1.29.2-alpine@sha256:61e01287e546aac28a3f56839c136b31f590273f3b41187a36f46f6a03bbfe22"
  @sources "test/support/image_pipe/test/sources"
  @perf_sources "test/support/image_pipe/test/perf/sources"
  @perf_photo "priv/static/images/flower.jpg"
  @family_keys [
    {"watermark", ["wm"]},
    {"trim", ["trim"]},
    {"effects", ["blur", "sharpen", "pixelate"]},
    {"orientation", ["rotate", "flip", "orient"]},
    {"canvas", ["extend", "pad", "bg"]},
    {"crop", ["crop", "region"]},
    {"output", ["format", "q", "hdr", "profile", "meta"]}
  ]
  @families ["resize" | Enum.map(@family_keys, &elem(&1, 0))] ++ PerfCases.families()
  # `--only perf`: a few reference cases per family, over every kind of
  # source, and the `:pr` tier of `PerfCases`, for a comparison short enough to
  # run on every `perf` pull request. Most of the reference cases are anchor
  # and offset variants that cost the same. `--only nightly` adds the rest of
  # `PerfCases`.
  @perf_set ~w(
    rs_fill_zone webp_cover_offset cover_smart_marker
    alpha_resize cmyk_import palette_fit enlarge_small
    crop_gravity_placement crop_smart_marker region_odd_origin
    extend_small padding_border alpha_extend_bg
    rotate_exif exif_large_fit exif_user_rot90 exif_cover_smart rgb16_rotate_crop
    alpha_border_trim trim_resize_high_freq trim_icc_p3
    blur_zone sharpen_zone pixelate_marker rgba16_blur
    wm_center_scaled wm_tile gray_watermark wm_on_exif_frame
    lossy_avif lossy_webp scp0_colorspace_124 rgb16_preserve_hdr
  )
  # Sources whose content the cases don't depend on, so the cases also make
  # sense on a corpus photo.
  @generic_sources ~w(high_freq.jpg high_freq.webp marker.png placement.png small.png)
  # A case's measurement window is long enough for about this many sequential
  # requests, between `--duration` and `@max_window` seconds.
  @window_requests 15
  @max_window 10
  # The `origin` source's origin. `/r/<token>/` in front of a path serves the
  # same file under a new URL, so each `random: :source` request downloads a
  # new original. `/slow/r/<token>/` does too, at a rate that takes about a
  # second for a burst's 2 MP source.
  @origin_conf """
  server {
    listen 80;
    root /srv;
    location ~ ^/r/[^/]+/(.+)$ {
      alias /srv/$1;
    }
    location ~ ^/slow/r/[^/]+/(.+)$ {
      alias /srv/$1;
      limit_rate 512k;
    }
  }
  """
  @configs [:plain, :cached] ++
             for(caches <- [:none, :output, :overload], do: {:burst, caches})
  # Bursts per image and round for each `concurrency` case.
  @bursts 3
  # The stage log line each generation writes.
  @generation_line "image_pipe transform execute:"
  # The line the default Logger writes for a cache write it drops.
  @drop_line "stage_dropped"
  # ImagePipe servers check signatures, so the bench signs every request with
  # this key. Every image compared, old or new, accepts a 32-byte hex key.
  @signing_key String.duplicate("0123456789abcdef", 4)
  # How many signed URLs a `random` case gives oha, which draws one at random
  # for each request. A window sends at most a few thousand, so few repeat.
  @random_urls 100_000
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
    rounds: :integer,
    describe: :keep,
    shard: :string,
    merge: :keep
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    output = opts[:output] || "tmp/imgproxy_bench"
    results_path = Path.join(output, "results.json")

    cond do
      opts[:report_only] ->
        results = results_path |> File.read!() |> JSON.decode!()
        write_report!(output, results)

      opts[:merge] ->
        results =
          opts
          |> Keyword.get_values(:merge)
          |> Enum.map(&(&1 |> Path.join("results.json") |> File.read!() |> JSON.decode!()))
          |> Merge.merge()

        File.mkdir_p!(output)
        File.write!(results_path, JSON.encode!(results))
        write_report!(output, results)

      true ->
        run_bench(opts, output, results_path)
    end
  end

  defp run_bench(opts, output, results_path) do
    Mix.Task.run("app.start")
    json = opts |> bench(output) |> JSON.encode!()
    File.mkdir_p!(output)
    File.write!(results_path, json)
    write_report!(output, JSON.decode!(json))
  end

  # -- Setup -----------------------------------------------------------------

  defp bench(opts, output) do
    host_cpus = String.to_integer(Container.docker!(["info", "--format", "{{.NCPU}}"]))
    cpus = opts[:cpus] || 4

    if cpus >= host_cpus do
      Mix.raise("--cpus #{cpus} leaves no CPU for oha; Docker sees #{host_cpus}")
    end

    network = "imgproxy-bench-#{token()}"

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
      origin: "#{network}-origin",
      servers: servers(opts),
      rounds: opts[:rounds] || 4,
      shard: shard(opts[:shard]),
      progress: nil,
      descriptions: descriptions(opts),
      work: Path.expand(Path.join(output, "work")),
      windows: %{}
    }

    sources = write_work!(settings)

    cases =
      Cases.all()
      |> Enum.map(&Map.put(&1, :family, family(&1)))
      |> Kernel.++(corpus_cases(opts[:corpus], sources))
      |> Kernel.++(perf_cases(settings))
      |> select(opts[:only])

    Mix.shell().info(
      "#{length(cases)} case(s), about #{estimate_minutes(cases, settings)} min. " <>
        "Servers on CPUs #{settings.server_cpus}, oha on #{settings.oha_cpus}."
    )

    Container.docker!(["network", "create", settings.network])

    try do
      # One oha container serves every measurement, through `docker exec`. It
      # reads `random` cases' URL files from the work directory.
      Container.docker!(
        ["run", "-d", "--name", settings.oha, "--network", settings.network] ++
          ["-v", "#{settings.work}:/work:ro"] ++
          ["--cpuset-cpus", settings.oha_cpus, "--entrypoint", "sleep", @oha, "infinity"]
      )

      start_origin(settings, cases)
      run_servers(cases, settings)
    after
      Container.docker(["rm", "-f", settings.origin])
      Container.docker(["rm", "-f", settings.oha])
      Container.docker(["network", "rm", settings.network])
    end
  end

  # The sources, server configurations and origin configuration the
  # containers mount. Returns the sources directory.
  defp write_work!(settings) do
    File.rm_rf!(settings.work)
    sources = Path.join(settings.work, "sources")
    File.mkdir_p!(sources)
    File.cp_r!(@sources, sources)
    File.cp_r!(@perf_sources, Path.join(sources, "perf"))
    File.cp!(@perf_photo, Path.join(sources, "perf/photo12.jpg"))

    for config <- @configs do
      File.write!(Path.join(settings.work, config_file(config)), server_config(settings, config))
    end

    File.write!(Path.join(settings.work, "origin.conf"), @origin_conf)
    sources
  end

  # ImagePipe-only cases have no imgproxy request, so only a comparison of
  # ImagePipe images times them.
  defp perf_cases(%{servers: nil}), do: []
  defp perf_cases(settings), do: PerfCases.all() ++ PerfCases.bursts(settings.concurrency)

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

  defp descriptions(opts) do
    Map.new(Keyword.get_values(opts, :describe), fn value ->
      case String.split(value, "=", parts: 2) do
        [name, text] -> {name, text}
        _other -> Mix.raise("--describe takes NAME=TEXT, got #{inspect(value)}")
      end
    end)
  end

  defp against(value) do
    case String.split(value, "=", parts: 2) do
      [name, image] when name != "" and image != "" -> {name, image}
      _other -> Mix.raise("--against takes NAME=IMAGE, got #{inspect(value)}")
    end
  end

  defp run_servers(cases, %{servers: nil} = settings) do
    servers = [imgproxy_server(settings), image_pipe_server(settings)]
    {checks, timed, mismatched, windows} = check_servers(servers, cases, settings)
    settings = %{settings | progress: progress(timed, length(servers)), windows: windows}

    runs =
      Map.new(servers, fn server ->
        {server.key, measure_server(server, timed, settings)}
      end)

    %{
      "environment" => environment(settings, runs),
      "cases" => Enum.map(timed, &case_result(&1, runs, settings.windows)),
      "baseline" => Map.new(runs, fn {key, run} -> {key, run.baseline} end),
      "mismatches" => Enum.map(mismatched, &mismatch(&1, checks))
    }
  end

  defp run_servers(cases, settings) do
    servers =
      for {key, image} <- settings.servers, do: image_pipe_server(settings, key, image)

    {bursts, cases} = Enum.split_with(cases, &burst?/1)

    with_server(hd(servers), settings, :plain, &make_variants(&1, settings))
    {checks, timed, mismatched, windows} = check_servers(servers, cases, settings)

    round_numbers = shard_rounds(settings.rounds, settings.shard)

    settings = %{
      settings
      | progress: progress(timed, length(servers) * length(round_numbers)),
        windows: windows
    }

    # Alternate rounds run the images in reverse order.
    rounds =
      for round <- round_numbers do
        order = if rem(round, 2) == 1, do: servers, else: Enum.reverse(servers)
        Mix.shell().info("Round #{round}/#{settings.rounds}")
        stage = "round #{round}/#{settings.rounds}, "

        Map.new(order, fn server ->
          run = measure_server(server, timed, settings, stage)
          {server.key, Map.put(run, :bursts, run_bursts(server, bursts, settings))}
        end)
      end

    [first | _] = rounds

    %{
      "mode" => "compare",
      "shard" => %{"count" => elem(settings.shard, 1), "rounds" => round_numbers},
      "candidate" => "candidate",
      "against" => for({key, _image} <- tl(settings.servers), do: key),
      "environment" => environment(settings, first),
      "cases" => Enum.map(timed, &compare_result(&1, rounds, settings.windows)),
      "bursts" => Enum.map(bursts, &burst_result(&1, rounds)),
      "baseline" =>
        Map.new(servers, fn s -> {s.key, Enum.map(rounds, &Map.fetch!(&1, s.key).baseline)} end),
      "mismatches" => Enum.map(mismatched, &mismatch(&1, checks))
    }
  end

  # `--shard I/N`: this run is shard I of N.
  defp shard(nil), do: {1, 1}

  defp shard(value) do
    with [index, count] <- String.split(value, "/"),
         {index, ""} <- Integer.parse(index),
         {count, ""} <- Integer.parse(count),
         true <- index in 1..count//1 do
      {index, count}
    else
      _invalid -> Mix.raise("--shard takes I/N with 1 ≤ I ≤ N, got #{inspect(value)}")
    end
  end

  # Shard I of N runs rounds I, I + N, I + 2N, and so on.
  defp shard_rounds(rounds, {index, count}) do
    case Enum.filter(1..rounds, &(rem(&1 - 1, count) == index - 1)) do
      [] -> Mix.raise("--shard #{index}/#{count} has none of the #{rounds} round(s)")
      numbers -> numbers
    end
  end

  # Also sizes each case's measurement window from the slowest server's time
  # for it, so every server measures a case for as long.
  defp check_servers(servers, cases, settings) do
    results =
      Map.new(servers, fn server ->
        {checks, times} =
          server
          |> each_config(by_config(cases), settings, fn info, _config, group ->
            check_all(server, group, info)
          end)
          |> Enum.reduce({%{}, %{}}, fn {checks, times}, {all_checks, all_times} ->
            {Map.merge(all_checks, checks), Map.merge(all_times, times)}
          end)

        {server.key, {checks, times}}
      end)

    checks = Map.new(results, fn {key, {checked, _times}} -> {key, checked} end)
    {timed, mismatched} = Enum.split_with(cases, &matches?(checks, &1))

    windows =
      Map.new(timed, fn c ->
        slowest =
          results |> Enum.map(fn {_key, {_checked, times}} -> times[c.id] end) |> Enum.max()

        {c.id, window(slowest, settings.duration)}
      end)

    {checks, timed, mismatched, windows}
  end

  defp window(seconds, duration),
    do: (seconds * @window_requests) |> ceil() |> max(duration) |> min(@max_window)

  # The candidate makes the photo variants `PerfCases` reads, so every image
  # compared reads the same files.
  defp make_variants(info, settings) do
    Mix.shell().info("Making #{length(PerfCases.variants())} photo variants")

    for {file, request} <- PerfCases.variants() do
      url = info.base_url <> sign("/#{request}/src/perf/photo12.jpg")

      case Req.get(url, decode_body: false, retry: false, receive_timeout: 300_000) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          File.write!(Path.join([settings.work, "sources", "perf", file]), body)

        other ->
          Mix.raise("Couldn't make perf/#{file} with #{request}: #{inspect(other)}")
      end
    end
  end

  defp imgproxy_server(settings) do
    %{
      key: "imgproxy",
      label: "imgproxy #{Container.version()}",
      image: Container.image(),
      health: "/health",
      configurable: false,
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
      configurable: true,
      path: &sign(Container.native_path(&1)),
      libvips: &Container.libvips(&1, "/usr/local/lib"),
      args:
        Enum.flat_map(settings.server_env, &["-e", &1]) ++
          [
            "--read-only",
            "--tmpfs",
            "/tmp",
            "-v",
            "#{Path.join(settings.work, "sources")}:/data/images:ro"
          ]
    }
  end

  # imgproxy's AVIF speed 8 is libvips effort 1 (`9 - speed`); both default
  # to WebP effort 4. imgproxy checks no signatures, and the bench signs
  # ImagePipe's requests. Only the `:cached` configuration and the bursts have
  # caches. They sit in the image's `/var/cache/image_pipe` volume, not on the
  # `/tmp` tmpfs, whose pages would count as the server's memory. Their sizes
  # leave a measurement window nothing to evict.
  defp server_config(settings, config) do
    plain_config(settings, config) <> extra_config(config, settings)
  end

  defp extra_config(:plain, _settings), do: ""
  defp extra_config(:cached, settings), do: origin_config(settings) <> caches_config(:output)

  # A burst's generations are counted from the stage log.
  defp extra_config({:burst, caches}, settings) do
    origin_config(settings) <>
      caches_config(caches) <>
      """

      [telemetry]
      log_stages = true
      """
  end

  defp origin_config(settings) do
    """

    [sources.origin]
    adapter = "http"
    match = { prefix = "origin" }
    base_url = "http://#{settings.origin}"
    stable = "immutable"
    cache_policy = { storage = "allow" }
    address_policy.allow_private = true
    """
  end

  defp caches_config(:none), do: ""
  defp caches_config(:overload), do: caches_config(:output)

  defp caches_config(:output) do
    """

    [cache.output]
    root = "/var/cache/image_pipe/output"
    max_size_bytes = 50_000_000_000
    """
  end

  defp plain_config(settings, config) do
    """
    [url]
    keys = ["#{@signing_key}"]

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
    processing_timeout = 120000
    #{queue_config(config)}
    """
  end

  # A queue nothing overflows, except in the bursts that measure overload,
  # which keep the server's defaults.
  defp queue_config({:burst, :overload}), do: ""

  defp queue_config(_config) do
    """
    max_queue = 4096
    queue_timeout = 120000
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
    names = Enum.flat_map(names, &expand(&1, cases))
    selected = Enum.filter(cases, &(&1.id in names or &1.family in names))
    unknown = Enum.reject(names, &(&1 in @families or Enum.any?(cases, fn c -> c.id == &1 end)))
    if unknown != [], do: Mix.raise("Unknown case id(s) or families: #{Enum.join(unknown, ", ")}")
    selected
  end

  # `perf` and `nightly` name the case sets the workflow runs. `PerfCases` are
  # among the cases only when comparing ImagePipe images.
  defp expand("perf", cases),
    do: @perf_set ++ for(%{tier: :pr, id: id} <- cases, do: id)

  defp expand("nightly", cases),
    do: @perf_set ++ for(%{tier: _tier, id: id} <- cases, do: id)

  defp expand(name, _cases), do: [name]

  # The warm-up and the two `docker exec` calls add about a second a case.
  defp estimate_minutes(cases, %{servers: nil} = settings),
    do: ceil(length(cases) * 2 * (2 * settings.duration + 1) / 60)

  # A burst takes about two seconds, an overload burst about its queue timeout
  # and the encodes already started, and its container about five to start.
  defp estimate_minutes(cases, settings) do
    runs = length(settings.servers) * length(shard_rounds(settings.rounds, settings.shard))
    {bursts, cases} = Enum.split_with(cases, &burst?/1)
    burst_seconds = Enum.sum_by(bursts, &(burst_seconds(&1) * @bursts + 5))
    seconds = length(cases) * (2 * settings.duration + 1) + burst_seconds
    ceil(runs * seconds / 60)
  end

  defp burst_seconds(%{config: {:burst, :overload}}), do: 15
  defp burst_seconds(_burst), do: 2

  defp burst?(c), do: Map.get(c, :kind) == :burst

  # -- Servers ---------------------------------------------------------------

  defp config(c), do: Map.get(c, :config, :plain)

  defp config_file(:plain), do: "config.toml"
  defp config_file(:cached), do: "config-cached.toml"
  defp config_file({:burst, caches}), do: "config-burst-#{caches}.toml"

  # Only the `:plain` configuration doesn't read from the origin.
  defp start_origin(settings, cases) do
    if Enum.any?(cases, &(config(&1) != :plain)), do: run_origin(settings)
  end

  defp run_origin(settings) do
    Container.docker!(
      ["run", "-d", "--name", settings.origin, "--network", settings.network] ++
        ["--cpuset-cpus", settings.oha_cpus] ++
        ["-v", "#{Path.join(settings.work, "sources")}:/srv:ro"] ++
        ["-v", "#{Path.join(settings.work, "origin.conf")}:/etc/nginx/conf.d/default.conf:ro"] ++
        [@nginx]
    )
  end

  # The cases grouped by configuration, the plain one first.
  defp by_config(cases) do
    cases
    |> Enum.group_by(&config/1)
    |> Enum.sort_by(fn {config, _group} -> config != :plain end)
  end

  # Runs `fun` in a container for each `{config, cases}` group, with that
  # configuration's cases.
  defp each_config(server, groups, settings, fun) do
    Enum.map(groups, fn {config, group} ->
      with_server(server, settings, config, &fun.(&1, config, group))
    end)
  end

  defp with_server(server, settings, config, fun) do
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
      ] ++ server.args ++ config_args(server, settings, config) ++ [server.image]
    )

    try do
      base_url = "http://127.0.0.1:#{Container.mapped_port!(name)}"
      wait_until_ready!(name, base_url <> server.health)
      fun.(%{name: name, base_url: base_url})
    after
      Container.docker(["rm", "-f", "-v", name])
    end
  end

  defp config_args(%{configurable: false}, _settings, :plain), do: []

  defp config_args(%{configurable: true}, settings, config) do
    path = Path.join(settings.work, config_file(config))
    ["-v", "#{path}:/etc/image_pipe/config.toml:ro"]
  end

  defp wait_until_ready!(name, url) do
    Container.wait_until_ready!(url)
  rescue
    error in Mix.Error ->
      {logs, _} = System.cmd("docker", ["logs", "--tail", "20", name], stderr_to_stdout: true)
      Mix.raise(error.message <> "\n" <> logs)
  end

  # Each case's check, and the fastest of three timed requests after it, in
  # seconds.
  defp check_all(server, cases, info) do
    Mix.shell().info("Checking #{server.label}")

    results =
      Map.new(cases, fn c ->
        url = fn -> info.base_url <> case_path(server, c) end
        {c.id, {check(url.()), request_seconds(url)}}
      end)

    {Map.new(results, fn {id, {checked, _time}} -> {id, checked} end),
     Map.new(results, fn {id, {_checked, time}} -> {id, time} end)}
  end

  defp request_seconds(url) do
    1..3
    |> Enum.map(fn _ ->
      url = url.()

      {us, _result} =
        :timer.tc(fn ->
          Req.get(url, decode_body: false, retry: false, receive_timeout: 120_000)
        end)

      us / 1_000_000
    end)
    |> Enum.min()
  end

  # A response the bench can't read counts as a mismatch, not a crash.
  defp check(url) do
    with {:ok, %Req.Response{status: 200, body: body} = response} <-
           Req.get(url, decode_body: false, retry: false, receive_timeout: 120_000),
         [content_type] <- Req.Response.get_header(response, "content-type") do
      checked(content_type, body)
    else
      {:ok, %Req.Response{status: status}} -> %{"status" => status}
      {:error, %{__exception__: true} = exception} -> %{"status" => Exception.message(exception)}
      _headers -> %{"status" => "200 with no single content type"}
    end
  end

  # A response that isn't an image, such as `output=info`, is compared by
  # content type alone.
  defp checked("image/" <> _subtype = content_type, body) do
    case Image.open(body, access: :random) do
      {:ok, image} ->
        %{
          "status" => 200,
          "content_type" => content_type,
          "width" => Image.width(image),
          "height" => Image.height(image)
        }

      {:error, reason} ->
        %{"status" => "200 that doesn't decode: #{inspect(reason)}"}
    end
  end

  defp checked(content_type, _body), do: %{"status" => 200, "content_type" => content_type}

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

  # The baseline, libvips version and so on come from the first container.
  defp measure_server(server, cases, settings, stage \\ "") do
    Mix.shell().info("Timing #{server.label}")
    levels = Enum.uniq([1, settings.concurrency])
    indexes = cases |> Enum.with_index(1) |> Map.new(fn {c, index} -> {c.id, index} end)

    # With only bursts selected, a plain container still gives the baseline.
    groups = if cases == [], do: [{:plain, []}], else: by_config(cases)

    [first | rest] =
      each_config(server, groups, settings, fn info, _config, group ->
        url = &"http://#{info.name}:8080#{&1}"

        baseline =
          Map.new(
            levels,
            &{"#{&1}", measure([url.(server.health)], &1, settings.duration, settings, info.name)}
          )

        timings =
          Map.new(group, fn c ->
            target = oha_target(server, c, url, settings)
            warm_up(target, settings)
            window = Map.fetch!(settings.windows, c.id)
            timing = Map.new(levels, &{"#{&1}", measure(target, &1, window, settings, info.name)})
            index = Map.fetch!(indexes, c.id)
            report_progress(settings.progress, "#{stage}#{server.key}", index, length(cases))
            {c.id, timing}
          end)

        %{baseline: baseline, timings: timings, libvips: server.libvips.(info.name)}
      end)

    %{
      baseline: first.baseline,
      timings: Enum.reduce(rest, first.timings, &Map.merge(&2, &1.timings)),
      libvips: first.libvips,
      image: server.image,
      image_id: Container.docker!(["image", "inspect", "--format", "{{.Id}}", server.image]),
      label: server.label
    }
  end

  # Each burst case's bursts: `%{"ms", "downloads", "generations", "drops",
  # "rejected", "rejected_ms"}` for each.
  defp run_bursts(server, bursts, settings) do
    server
    |> each_config(by_config(bursts), settings, fn info, _config, group ->
      Map.new(group, fn b ->
        {b.id, Enum.map(1..@bursts, fn _ -> burst(b, info, settings) end)}
      end)
    end)
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  # Sends a burst's requests at once, for source paths no request has used.
  # Logger writes a request's stage lines around its response, so the counts
  # wait a moment for them.
  defp burst(b, info, settings) do
    token = token()
    before = log_count(info.name, @generation_line)
    dropped = log_count(info.name, @drop_line)
    finch = burst_finch(length(b.natives))
    started = System.monotonic_time(:millisecond)

    responses =
      b.natives
      |> Enum.with_index()
      |> Task.async_stream(
        fn {native, index} ->
          sent = System.monotonic_time(:millisecond)

          response =
            Req.get(
              info.base_url <> sign("/#{native}/src/origin/#{burst_source(b, token, index)}"),
              finch: [name: finch],
              decode_body: false,
              retry: false,
              receive_timeout: 120_000
            )

          {response, System.monotonic_time(:millisecond) - sent}
        end,
        max_concurrency: length(b.natives),
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, {{:ok, %Req.Response{status: status}}, ms}} -> {status, ms}
        other -> {inspect(other), nil}
      end)

    ms = System.monotonic_time(:millisecond) - started
    statuses = Enum.map(responses, &elem(&1, 0))
    allowed = if b.config == {:burst, :overload}, do: [200, 503], else: [200]

    if Enum.any?(statuses, &(&1 not in allowed)),
      do: Mix.raise("#{b.id} got #{inspect(statuses)}")

    Process.sleep(500)
    rejected = for {503, ms} <- responses, do: ms

    %{
      "ms" => ms,
      "downloads" => log_count(settings.origin, "/r/#{token}"),
      "generations" => log_count(info.name, @generation_line) - before,
      "drops" => log_count(info.name, @drop_line) - dropped,
      "rejected" => length(rejected),
      "rejected_ms" => rejected
    }
  end

  # Req's default pool holds 50 connections, fewer than `burst_grid` sends at
  # once.
  defp burst_finch(size) do
    name = Module.concat(__MODULE__, "BurstFinch#{size}")

    case Finch.start_link(name: name, pools: %{default: [size: size]}) do
      {:ok, _pid} -> name
      {:error, {:already_started, _pid}} -> name
    end
  end

  # `:one` paces a single original so the requests overlap its download.
  defp burst_source(%{originals: :one} = b, token, _index), do: "slow/r/#{token}/#{b.source}"
  defp burst_source(%{originals: :each} = b, token, index), do: "r/#{token}-#{index}/#{b.source}"

  defp log_count(container, needle) do
    {logs, 0} = System.cmd("docker", ["logs", container], stderr_to_stdout: true)
    logs |> String.split("\n") |> Enum.count(&String.contains?(&1, needle))
  end

  # A case's path. A `random` case gets a new token on every call.
  defp case_path(server, c), do: server.path.(randomize(c, token()))

  defp token, do: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)

  defp randomize(%{random: :output} = c, token), do: %{c | native: "cb=#{token}/#{c.native}"}

  defp randomize(%{random: :source, source: "origin/" <> path} = c, token),
    do: %{c | source: "origin/r/#{token}/#{path}"}

  defp randomize(c, _token), do: c

  # oha's URL arguments for a case. A `random` case's URLs are signed, so oha
  # can't generate them: it gets a file of new ones for each measurement.
  defp oha_target(server, c, url, settings) do
    case Map.get(c, :random) do
      nil ->
        [url.(server.path.(c))]

      _random ->
        name = "urls-#{server.key}-#{c.id}.txt"
        urls = for _ <- 1..@random_urls, do: [url.(case_path(server, c)), ?\n]
        File.write!(Path.join(settings.work, name), urls)
        ["--urls-from-file", "/work/#{name}"]
    end
  end

  defp sign(path), do: ImagePipe.URL.sign_path(path, url_config())

  defp url_config do
    with nil <- :persistent_term.get({__MODULE__, :url_config}, nil) do
      config = ImagePipe.URL.config(keys: [@signing_key])
      :persistent_term.put({__MODULE__, :url_config}, config)
      config
    end
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

  # Every case answered 200 in its check, so another status here means oha
  # requested something else.
  defp warm_up(target, settings) do
    load =
      oha(
        ["-n", "#{2 * settings.concurrency}", "-c", "#{settings.concurrency}"] ++ target,
        settings
      )

    statuses = load["statusCodeDistribution"]
    if Map.keys(statuses) != ["200"], do: Mix.raise("Warm-up got #{inspect(statuses)}")
  end

  # Reads the server's cgroup: CPU time over the run, and memory sampled every
  # 200 ms while oha runs.
  defp measure(target, concurrency, window, settings, container) do
    cpu_before = cpu_usec(container)
    started = System.monotonic_time(:microsecond)
    sampler = Task.async(fn -> sample_memory(container, nil) end)
    load = oha(["-z", "#{window}s", "-c", "#{concurrency}", "-w"] ++ target, settings)
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

  defp case_result(c, runs, windows) do
    %{
      "id" => c.id,
      "family" => c.family,
      "source" => c.source,
      "native" => c.native,
      "imgproxy" => c.imgproxy,
      "window_s" => Map.fetch!(windows, c.id),
      "timings" => Map.new(runs, fn {key, run} -> {key, Map.fetch!(run.timings, c.id)} end)
    }
  end

  defp compare_result(c, rounds, windows) do
    %{
      "id" => c.id,
      "family" => c.family,
      "source" => c.source,
      "native" => c.native,
      "window_s" => Map.fetch!(windows, c.id),
      "rounds" =>
        rounds
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Map.new(fn key ->
          {key, Enum.map(rounds, &Map.fetch!(Map.fetch!(&1, key).timings, c.id))}
        end)
    }
  end

  defp burst_result(b, rounds) do
    {:burst, caches} = b.config

    %{
      "id" => b.id,
      "caches" => Atom.to_string(caches),
      "requests" => length(b.natives),
      "natives" => Enum.uniq(b.natives),
      "rounds" =>
        rounds
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Map.new(fn key ->
          {key, Enum.map(rounds, &Map.fetch!(Map.fetch!(&1, key).bursts, b.id))}
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
      "rounds" => length(shard_rounds(settings.rounds, settings.shard)),
      "oha" => @oha,
      "servers" =>
        Map.new(runs, fn {key, run} ->
          {key,
           %{
             "label" => run.label,
             "image" => run.image,
             "description" => Map.get(settings.descriptions, key),
             "image_id" => run.image_id,
             "libvips" => run.libvips
           }}
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
