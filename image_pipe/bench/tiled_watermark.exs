# Run from image_pipe/; optional baseline source is loaded only in worker VMs:
# mise exec -- mix run bench/tiled_watermark.exs matrix /tmp/watermark [baseline.ex]
# Fresh VMs isolate libvips memory high-water counters. Timing covers complete
# uncached Plug requests after warmup; verification runs after the peak snapshot.
# Operation cache is disabled; set WATERMARK_BENCH_CACHE=100 for a cached run.
defmodule TiledWatermarkBench do
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @cases ~w(tiled_800 tiled_2400 small_tiled single_800 single_2400)

  def main(["matrix", root | baseline]) do
    prepare(root)

    rows =
      for scenario <- @cases, trial <- 1..3, variant <- variants(baseline, trial) do
        {name, override} = variant
        args = ["worker", root, scenario, name, Integer.to_string(trial)] ++ override

        {output, 0} =
          System.cmd("mix", ["run", "--no-compile", __ENV__.file | args], stderr_to_stdout: true)

        row = output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
        IO.puts(JSON.encode!(row))
        row
      end

    for scenario <- @cases do
      hashes =
        rows
        |> Enum.filter(&(&1["scenario"] == scenario))
        |> Enum.map(&{&1["dimensions"], &1["pixel_sha256"], &1["body_sha256"]})
        |> Enum.uniq()

      [_same_pixels_and_bytes] = hashes
    end

    File.write!(Path.join(root, "results.json"), JSON.encode!(rows))
  end

  def main(["worker", root, scenario, variant, trial | override]) do
    for {app, _, _} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        do: Code.ensure_loaded(module)

    Enum.each(override, &Code.compile_file/1)
    cache_limit = System.get_env("WATERMARK_BENCH_CACHE", "0") |> String.to_integer()
    Vix.Vips.cache_set_max(cache_limit)
    if cache_limit == 0, do: Vix.Vips.cache_set_max_mem(0)
    Vix.Vips.concurrency_set(2)

    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: root, root_id: "watermark-bench", stable: :immutable]
          ]
        ],
        watermarks: %{large: [source: "large.png"], small: [source: "small.png"]}
      )

    path = "/#{options(scenario)}/wm-opacity=0.6/format=png/src/frame.jpg"
    request(config, path)
    :erlang.garbage_collect()

    samples =
      Enum.map(1..5, fn _ ->
        {elapsed, body} = :timer.tc(fn -> request(config, path) end)
        {elapsed / 1000, body}
      end)

    peak = Vix.Vips.tracked_get_mem_highwater()
    {_, body} = List.last(samples)
    image = Image.from_binary!(body)
    {:ok, pixels} = VipsImage.write_to_binary(image)

    IO.puts(
      JSON.encode!(%{
        scenario: scenario,
        variant: variant,
        trial: String.to_integer(trial),
        operation_cache_limit: cache_limit,
        elapsed_ms: Enum.map(samples, &elem(&1, 0)),
        median_ms: samples |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(2),
        libvips_peak_bytes: peak,
        dimensions: [Image.width(image), Image.height(image)],
        pixel_sha256: digest(pixels),
        body_sha256: digest(body),
        vips: Vix.Vips.version(),
        elixir: System.version(),
        otp: System.otp_release()
      })
    )
  end

  defp variants([], _trial), do: [{"current", []}]

  defp variants([baseline], trial) do
    variants = [{"baseline", [Path.expand(baseline)]}, {"current", []}]
    if rem(trial, 2) == 0, do: Enum.reverse(variants), else: variants
  end

  defp prepare(root) do
    File.mkdir_p!(root)
    File.cp!("priv/static/images/beach.jpg", Path.join(root, "frame.jpg"))

    for {name, width, height} <- [{"large", 1200, 600}, {"small", 64, 32}] do
      pixels =
        for y <- 0..(height - 1),
            x <- 0..(width - 1),
            into: <<>>,
            do: <<rem(x, 256), rem(y, 256), 160, 80 + rem(x + y, 176)>>

      {:ok, image} = VipsImage.new_from_binary(pixels, width, height, 4, :VIPS_FORMAT_UCHAR)
      image = Operation.copy!(image, interpretation: :VIPS_INTERPRETATION_sRGB)
      Image.write!(image, Path.join(root, name <> ".png"))
    end
  end

  defp request(config, path) do
    response = Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(config)
    if response.status != 200, do: raise("HTTP #{response.status}: #{response.resp_body}")
    drain_sent()
    response.resp_body
  end

  defp drain_sent do
    receive do
      {:plug_conn, :sent} -> drain_sent()
      {ref, _response} when is_reference(ref) -> drain_sent()
    after
      0 -> :ok
    end
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp options("tiled_800"), do: "w=800/wm=large/wm-scale=0.2/wm-tile"
  defp options("tiled_2400"), do: "w=2400/wm=large/wm-scale=0.1/wm-tile"
  defp options("small_tiled"), do: "w=800/wm=small/wm-tile"
  defp options("single_800"), do: "w=800/wm=large/wm-scale=0.2"
  defp options("single_2400"), do: "w=2400/wm=large/wm-scale=0.1"
end

TiledWatermarkBench.main(System.argv())
