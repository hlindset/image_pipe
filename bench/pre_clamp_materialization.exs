# Run the matrix in fresh VMs (high-water counters cannot be reset):
# mise exec -- mix run bench/pre_clamp_materialization.exs matrix /tmp/fd8
# Broader orientation/metadata audit:
# mise exec -- mix run bench/pre_clamp_materialization.exs audit /tmp/fd8-audit
# Remaining orientation boundaries, including a full-sized JPEG:
# mise exec -- mix run bench/pre_clamp_materialization.exs followup /tmp/fd8-followup
# Optional worker: ... worker /tmp/fd8 fit exif6 12000 8192
# Sources are lossless TIFFs made from the same decoded photograph. twin3/twin6
# contain physically oriented pixels, providing an early-orientation comparison.
# These comparisons are experiments, not pixel-equivalence guarantees.
defmodule PreClampMaterializationBench do
  @prefix [:pre_clamp_materialization_bench]

  def main(["matrix", root]) do
    prepare(root)

    cases =
      for scenario <- ~w(fit cover canvas padding groups),
          source <- ~w(plain exif3 exif6 twin3 twin6),
          do: {scenario, source, 6000, 2048}

    cases =
      cases ++
        for {target, cap} <- [{12000, :default}, {12000, 8192}, {12000, 10000}],
            source <- ~w(plain exif6 twin6),
            do: {"fit", source, target, cap}

    rows = run_cases(root, cases)
    compare(root, rows)
  end

  def main(["audit", root]) do
    prepare(root)

    Image.open!("test/support/image_pipe/test/sources/icc_p3.png")
    |> Image.write!(Path.join(root, "p3.tif"))

    linear_source = Image.open!("priv/static/images/beach.jpg") |> Image.resize!(0.25)
    {:ok, linear} = Vix.Vips.Operation.colourspace(linear_source, :VIPS_INTERPRETATION_scRGB)
    Image.write!(linear, Path.join(root, "scrgb.tif"))

    {:ok, unprofiled} =
      Vix.Vips.Image.mutate(linear, fn mutable ->
        Vix.Vips.MutableImage.remove(mutable, "icc-profile-data")
        :ok
      end)

    Image.write!(unprofiled, Path.join(root, "scrgb_unprofiled.tif"))

    cases =
      [
        {"fit", "plain", 3000, 1024},
        {"fit", "p3", 3000, 1024},
        {"fit", "scrgb", 128, 128},
        {"fit", "scrgb_unprofiled", 128, 128},
        {"horizontal", "plain", 3000, 1024},
        {"rotation_groups", "plain", 3000, 1024}
      ] ++
        for scenario <- ~w(metadata_keep metadata_strip profile_preserve profile_srgb),
            source <- ~w(plain p3),
            do: {scenario, source, 3000, 1024}

    run_cases(root, cases)
  end

  def main(["followup", root]) do
    prepare(root)
    File.cp!("priv/static/images/beach.jpg", Path.join(root, "jpeg.jpg"))

    run_cases(root, [
      {"fit", "plain", 6000, 2048},
      {"fit", "exif6", 6000, 2048},
      {"fit", "exif6", 12000, :default},
      {"cover", "exif6", 6000, 2048},
      {"thin_cover", "exif6", 6000, 2048},
      {"canvas", "exif6", 6000, 2048},
      {"padding", "exif6", 6000, 2048},
      {"groups", "exif6", 6000, 2048},
      {"rotated_fit", "jpeg", 2800, 2048},
      {"rotated_fit", "jpeg", 4500, 2048},
      {"rotated_fit", "jpeg", 128, 2048},
      {"orientation_keep", "exif6", 6000, 2048},
      {"orientation_strip", "exif6", 6000, 2048}
    ])
  end

  def main(["worker", root, scenario, source, target, cap]) do
    cap = if cap == "default", do: :default, else: String.to_integer(cap)
    worker(root, scenario, source, String.to_integer(target), cap)
  end

  def main(["compare", root]) do
    compare(root, root |> Path.join("results.json") |> File.read!() |> JSON.decode!())
  end

  defp run_cases(root, cases) do
    rows =
      Enum.map(cases, fn {scenario, source, target, cap} ->
        args = ["worker", root, scenario, source, to_string(target), to_string(cap)]

        {output, 0} =
          System.cmd("mix", ["run", "--no-compile", __ENV__.file | args], stderr_to_stdout: true)

        row = output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
        IO.puts(JSON.encode!(row))
        row
      end)

    File.write!(Path.join(root, "results.json"), JSON.encode!(rows))
    rows
  end

  defp prepare(root) do
    File.mkdir_p!(root)
    base = Image.open!("priv/static/images/beach.jpg") |> Image.resize!(0.15)

    for {name, image} <- [
          {"plain", Image.set_orientation!(base, 1)},
          {"exif3", Image.set_orientation!(base, 3)},
          {"exif6", Image.set_orientation!(base, 6)},
          {"twin3", base |> Image.rotate!(180) |> Image.set_orientation!(1)},
          {"twin6", base |> Image.rotate!(90) |> Image.set_orientation!(1)}
        ] do
      Image.write!(image, Path.join(root, name <> ".tif"))
    end
  end

  defp worker(root, scenario, source, target, cap) do
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)
    Vix.Vips.concurrency_set(2)
    events = :ets.new(:events, [:public, :ordered_set])

    :telemetry.attach_many(
      __MODULE__,
      Enum.map(
        [
          [:transform, :operation, :stop],
          [:transform, :materialize, :stop],
          [:transform, :input_color_management, :stop],
          [:output, :clamp],
          [:encode, :start],
          [:encode, :stop]
        ],
        &(@prefix ++ &1)
      ),
      &__MODULE__.event/4,
      events
    )

    config =
      ImagePipe.Plug.init(
        [
          sources: [path: {ImagePipe.Source.File, root: root, root_id: "fd8"}],
          telemetry_prefix: @prefix
        ] ++ limits(cap)
      )

    extension = if source == "jpeg", do: "jpg", else: "tif"
    path = "/#{options(scenario, target)}/format=png/src/#{source}.#{extension}"
    {us, conn} = :timer.tc(fn -> Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(config) end)
    if conn.status != 200, do: raise("#{path}: #{conn.status}: #{conn.resp_body}")
    peak = Vix.Vips.tracked_get_mem_highwater()
    name = Enum.join([scenario, source, target, cap], "-") <> ".png"
    File.write!(Path.join(root, name), conn.resp_body)

    # Decode for verification only after snapshotting request memory high-water.
    image = Image.from_binary!(conn.resp_body)
    {:ok, pixels} = Vix.Vips.Image.write_to_binary(image)

    IO.puts(
      JSON.encode!(%{
        scenario: scenario,
        source: source,
        target: target,
        cap: cap,
        max_result_pixels: config[:max_result_pixels],
        path: path,
        output: name,
        dimensions: [Image.width(image), Image.height(image)],
        pixel_sha256: Base.encode16(:crypto.hash(:sha256, pixels), case: :lower),
        libvips_peak_bytes: peak,
        elapsed_ms: us / 1000,
        vips: Vix.Vips.version(),
        events: Enum.map(:ets.tab2list(events), &elem(&1, 1))
      })
    )
  end

  def event(event, _measurements, metadata, table) do
    data = %{
      event: Enum.join(tl(event), "."),
      operation: metadata[:operation],
      dimensions: tuple_list(metadata[:dims] || metadata[:dimensions]),
      source_dimensions: tuple_list(metadata[:source_dimensions]),
      live_bytes: Vix.Vips.tracked_get_mem(),
      peak_bytes: Vix.Vips.tracked_get_mem_highwater()
    }

    :ets.insert(table, {System.unique_integer([:positive, :monotonic]), data})
  end

  defp tuple_list(nil), do: nil
  defp tuple_list(value), do: Tuple.to_list(value)

  defp limits(:default), do: []

  defp limits(cap),
    do: [max_result_width: cap, max_result_height: cap, max_result_pixels: 200_000_000]

  defp options("fit", size), do: "w=#{size}/enlarge"
  defp options("rotated_fit", size), do: "rotate=90/w=#{size}/enlarge"
  defp options("thin_cover", size), do: "w=2/h=#{size}/fit=cover/enlarge"
  defp options("orientation_keep", size), do: "orient=none/meta=keep/w=#{size}/enlarge"
  defp options("orientation_strip", size), do: "orient=none/meta=strip/w=#{size}/enlarge"
  defp options("cover", size), do: "w=#{size}/h=#{div(size, 3)}/fit=cover/enlarge"
  defp options("canvas", size), do: "w=#{size}/h=#{size}/enlarge/extend"
  defp options("padding", size), do: "w=#{size}/enlarge/pad=200,300,400,500"
  defp options("groups", size), do: "w=#{size}/enlarge/-/w=1500"
  defp options("horizontal", size), do: "flip=h/w=#{size}/enlarge"

  defp options("rotation_groups", size),
    do: "rotate=90/w=#{size}/enlarge/-/rotate=90/w=#{div(size, 2)}"

  defp options("metadata_keep", size), do: "w=#{size}/enlarge/meta=keep"
  defp options("metadata_strip", size), do: "w=#{size}/enlarge/meta=strip"
  defp options("profile_preserve", size), do: "w=#{size}/enlarge/profile=preserve"
  defp options("profile_srgb", size), do: "w=#{size}/enlarge/profile=srgb"

  defp compare(root, rows) do
    comparisons =
      for row <- rows, row["source"] in ["exif3", "exif6"] do
        twin = String.replace(row["source"], "exif", "twin")

        reference =
          Enum.find(rows, fn candidate ->
            candidate["source"] == twin and
              Enum.all?(~w(scenario target cap), &(candidate[&1] == row[&1]))
          end)

        actual = Image.open!(Path.join(root, row["output"]))
        expected = Image.open!(Path.join(root, reference["output"]))
        {:ok, difference} = Vix.Vips.Operation.subtract(actual, expected)
        {:ok, difference} = Vix.Vips.Operation.abs(difference)
        {:ok, {maximum, _}} = Vix.Vips.Operation.max(difference)
        {:ok, mean} = Vix.Vips.Operation.avg(difference)

        %{
          output: row["output"],
          reference: reference["output"],
          same_dimensions: row["dimensions"] == reference["dimensions"],
          identical_pixels: row["pixel_sha256"] == reference["pixel_sha256"],
          max_channel_error: maximum,
          mean_channel_error: mean
        }
      end

    File.write!(Path.join(root, "comparisons.json"), JSON.encode!(comparisons))
    Enum.each(comparisons, &IO.puts(JSON.encode!(&1)))
  end
end

PreClampMaterializationBench.main(System.argv())
