defmodule ImagePipe.WorkBudgetTest do
  # Counts the work representative requests do and compares it with a budget.
  # The counts don't depend on the machine or the libvips build, so a change
  # in them means the request path changed. Update a budget only when a
  # change means to alter that work, and say why in the commit. Each budget
  # names the regression it guards.
  #
  # Counting traces every process, so this module can't run async.
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.WorkCount

  @moduletag :tmp_dir

  @sources Path.expand("../support/image_pipe/test/sources", __DIR__)

  setup %{tmp_dir: dir} do
    sources = [
      path: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: @sources, root_id: "work-budget"]
      ]
    ]

    %{
      config:
        ImagePipe.Plug.init(
          allow_unsigned: true,
          sources: sources,
          watermarks: %{mark: [source: "alpha.png"]}
        ),
      # The file source keeps no stat evidence for a file changed in the
      # current second, and another test can change a shared source's ctime
      # just before this one runs. A clock ahead of the filesystem keeps the
      # evidence.
      cached:
        Caches.plug(
          Caches.start!(
            sources: sources,
            cache: [root: Path.join(dir, "cache")],
            clock: fn -> System.os_time(:second) + 2 end
          )
        ),
      dir: dir
    }
  end

  # `reads` counts full passes over the source from Erlang: hashing or
  # copying it. The format check's header peek is shorter than these sources.
  test "a crop that needs no shrink-on-load opens the source once", %{config: config} do
    assert_budget(config, "/crop=120,90/anchor=top-left/format=png/src/placement.png",
      loads: 1,
      copies: 4,
      reads: {"placement.png", 1}
    )
  end

  test "a JPEG resized down opens it twice: header, then shrink-on-load", %{config: config} do
    assert_budget(config, "/w=300/format=jpeg/src/high_freq.jpg",
      loads: 2,
      copies: 4,
      reads: {"high_freq.jpg", 1}
    )
  end

  test "trim searches a frame under a megapixel once", %{config: config} do
    assert_budget(config, "/trim=auto/format=png/src/alpha_border.png", find_trim: 1)
  end

  test "another size of an unchanged cached source doesn't read it again", %{cached: cached} do
    request(cached, "/w=100/format=jpeg/src/high_freq.jpg")

    assert_budget(cached, "/w=101/format=jpeg/src/high_freq.jpg",
      reads: {"high_freq.jpg", 0},
      opens: {"high_freq.jpg", 0}
    )
  end

  # The frame converts to sRGB once, before the watermark is drawn. Converting
  # the watermark into the source's profile and the result back to sRGB on
  # output takes 3.
  test "a watermark on a profiled source with sRGB output", %{config: config} do
    assert_budget(config, "/w=200/wm=mark/wm-scale=0.25/format=png/src/icc_p3.png", icc: 1)
  end

  # Keeping the source's profile leaves the old path: the watermark converts
  # into the profile, and the output exports to it.
  test "a watermark on a profiled source that keeps its profile", %{config: config} do
    assert_budget(
      config,
      "/w=200/wm=mark/wm-scale=0.25/profile=preserve/format=png/src/icc_p3.png",
      icc: 2
    )
  end

  # Delivery buffers the frame once. The conversion to sRGB and the header
  # edits after it stay lazy, so the frame isn't copied again.
  test "a profiled source converted to sRGB is buffered once", %{config: config} do
    assert_budget(config, "/format=png/src/icc_p3.png", copies: 4)
  end

  test "a CMYK source imports its profile once", %{config: config} do
    assert_budget(config, "/w=200/format=jpeg/src/cmyk.jpg", icc: 1)
  end

  # `buffer_loads` counts decodes from memory: each quality probe decodes its
  # candidate to score it.
  test "autoquality on a small WebP output probes three qualities", %{config: config} do
    assert_budget(config, "/w=200/autoquality=75/format=webp/src/high_freq.jpg", buffer_loads: 3)
  end

  # A later enlarge, pixelate, or sharpen reads the blurred image in
  # overlapping regions. Without a buffered blur result, each region
  # recomputes the blur, past what `max_blur_work` allows.
  test "a blur's result is buffered before a later enlarge", %{config: config} do
    assert_budget(config, "/blur=20/-/w=1000/enlarge/format=jpeg/src/high_freq.jpg", copies: 5)
  end

  test "a blur's result is buffered before a later pixelate", %{config: config} do
    assert_budget(config, "/blur=20/-/pixelate=4/format=jpeg/src/high_freq.jpg", copies: 5)
  end

  test "output=info reads the header and copies no pixels", %{config: config} do
    assert_budget(config, "/output=info/src/high_freq.jpg", loads: 1, copies: 0)
  end

  # AVIF has no shrink-on-load, so the header and pixels come from one open.
  test "an AVIF source resized down opens it once", %{dir: dir} do
    source = Path.join(dir, "avif")
    File.mkdir_p!(source)

    Image.write!(
      Image.open!(Path.join(@sources, "high_freq.jpg")),
      Path.join(source, "high_freq.avif")
    )

    config =
      ImagePipe.Plug.init(
        allow_unsigned: true,
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: source, root_id: "work-budget-avif"]
          ]
        ]
      )

    assert_budget(config, "/w=200/format=jpeg/src/high_freq.avif", loads: 1)
  end

  # JPEG has no alpha, so padding fills with the white the encoder would
  # flatten transparent padding onto.
  test "padding a JPEG adds no alpha to flatten", %{config: config} do
    assert_budget(config, "/w=300/pad=20/format=jpeg/src/high_freq.jpg", flatten: 0)
  end

  # Measures a second, identical request, so one-time setup doesn't count.
  defp assert_budget(config, path, budget) do
    request(config, path)
    {conn, work} = WorkCount.measure(fn -> request(config, path) end)
    assert conn.status == 200

    actual = Map.new(budget, fn {name, expected} -> {name, count(work, name, expected)} end)
    expected = Map.new(budget)

    assert actual == expected, """
    #{path} did different work than its budget.
    budget: #{inspect(expected)}
    actual: #{inspect(actual)}
    operations: #{inspect(work.operations)}
    """
  end

  defp count(work, :find_trim, _expected), do: Map.get(work.operations, "find_trim", 0)
  defp count(work, :flatten, _expected), do: Map.get(work.operations, "flatten", 0)

  defp count(work, :buffer_loads, _expected) do
    work.operations
    |> Enum.filter(fn {name, _count} -> name =~ ~r/^VipsForeignLoad.*Buffer$/ end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  defp count(work, :opens, {file, _opens}),
    do: {file, Map.get(work.file_opens, Path.join(@sources, file), 0)}

  defp count(work, :reads, {file, _passes}) do
    path = Path.join(@sources, file)
    {file, div(Map.get(work.file_bytes, path, 0), File.stat!(path).size)}
  end

  defp count(work, name, _expected), do: Map.fetch!(work, name)

  defp request(config, path), do: ImagePipe.Plug.call(conn(:get, path), config)
end
