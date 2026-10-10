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
      config: ImagePipe.Plug.init(sources: sources, watermarks: %{mark: [source: "alpha.png"]}),
      cached: ImagePipe.Plug.init(sources: sources, cache: [root: Path.join(dir, "cache")])
    }
  end

  # `reads` counts full passes over the source from Erlang: hashing or
  # copying it. The format check's header peek is shorter than these sources.
  test "a crop that needs no shrink-on-load opens the source once", %{config: config} do
    assert_budget(config, "/crop=120,90/anchor=top-left/format=png/src/placement.png",
      loads: 1,
      copies: 8,
      reads: {"placement.png", 1}
    )
  end

  test "a JPEG resized down opens it twice: header, then shrink-on-load", %{config: config} do
    assert_budget(config, "/w=300/format=jpeg/src/high_freq.jpg",
      loads: 2,
      copies: 10,
      reads: {"high_freq.jpg", 1}
    )
  end

  test "trim searches a frame under a megapixel once", %{config: config} do
    assert_budget(config, "/trim=auto/format=png/src/alpha_border.png", find_trim: 1)
  end

  test "another size of an unchanged cached source doesn't read it again", %{cached: cached} do
    request(cached, "/w=100/format=jpeg/src/high_freq.jpg")

    assert_budget(cached, "/w=101/format=jpeg/src/high_freq.jpg", reads: {"high_freq.jpg", 0})
  end

  # The watermark is converted into the source's profile and back to sRGB on
  # output (image_plug-1u3p would bring this to 1).
  test "a watermark on a profiled source with sRGB output", %{config: config} do
    assert_budget(config, "/w=200/wm=mark/wm-scale=0.25/format=png/src/icc_p3.png", icc: 3)
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

  defp count(work, :reads, {file, _passes}) do
    path = Path.join(@sources, file)
    {file, div(Map.get(work.file_bytes, path, 0), File.stat!(path).size)}
  end

  defp count(work, name, _expected), do: Map.fetch!(work, name)

  defp request(config, path), do: ImagePipe.Plug.call(conn(:get, path), config)
end
