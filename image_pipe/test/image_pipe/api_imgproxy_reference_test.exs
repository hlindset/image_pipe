defmodule ImagePipe.APIImgproxyReferenceTest do
  @moduledoc """
  Pixel references baked by upstream imgproxy and exercised through ImagePipe's
  URL API.

  See `test/support/image_pipe/test/imgproxy_reference/README.md` for fixture
  provenance and change rules. Every case writes its output, an amplified
  difference image and its result to `tmp/imgproxy_reference/`;
  `mix imgproxy.report` builds an HTML page and a summary from them.
  """

  use ExUnit.Case, async: true

  @moduletag :imgproxy_reference

  import Plug.Test

  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.ImgproxyReference.Cases
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/sources"
  @reference "test/support/image_pipe/test/imgproxy_reference"
  @fixtures Path.join(@reference, "fixtures")
  @results "tmp/imgproxy_reference"
  @manifest @reference |> Path.join("manifest.exs") |> Code.eval_file() |> elem(0)

  setup_all do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: @sources, root_id: "imgproxy-reference"]
          ]
        ],
        watermarks: %{mark: [source: "alpha.png"]}
      )

    File.rm_rf!(@results)
    File.mkdir_p!(@results)

    {:ok, config: config}
  end

  describe "reference" do
    for c <- Cases.all() do
      @case c
      if c[:pending], do: @tag(skip: c.pending)

      test "#{c.id}: #{c.native}", %{config: config} do
        check(@case, config)
      end
    end
  end

  describe "fixture integrity" do
    test "sources match the hashes the fixtures were baked from" do
      for {file, sha256} <- @manifest.sources do
        assert file_sha256(Path.join(@sources, file)) == sha256,
               "#{file} changed since the imgproxy fixtures were baked from it"
      end
    end

    test "every case has a manifest entry and every entry a case" do
      ids = MapSet.new(Cases.all(), & &1.id)
      assert ids == MapSet.new(Map.keys(@manifest.cases))
      assert length(Cases.all()) == MapSet.size(ids), "duplicate case ids"
    end

    test "fixtures match their recorded hashes and none are orphaned" do
      png_ids = for %{kind: :png, id: id} <- Cases.all(), do: id

      for id <- png_ids do
        assert file_sha256(fixture_path(id)) == @manifest.cases[id].fixture_sha256,
               "#{id}: fixture bytes changed; imgproxy fixtures are never re-baked"
      end

      assert @fixtures |> File.ls!() |> Enum.sort() ==
               png_ids |> Enum.map(&"#{&1}.png") |> Enum.sort()
    end

    test "every case source is recorded in the manifest" do
      for c <- Cases.all() do
        assert Map.has_key?(@manifest.sources, c.source), "#{c.id}: #{c.source} has no hash"
      end
    end
  end

  defp check(%{kind: :lossy} = c, config) do
    {body, content_type} = render(c.native, c.source, config)
    actual = Image.open!(body, access: :random, fail_on: :error)
    expected = @manifest.cases[c.id]
    dims = {Image.width(actual), Image.height(actual)}

    cond do
      dims != {expected.width, expected.height} ->
        fail_case(
          c.id,
          "dimensions #{inspect(dims)} != #{inspect({expected.width, expected.height})}"
        )

      content_type != expected.content_type ->
        fail_case(c.id, "content type #{content_type} != #{expected.content_type}")

      true ->
        record(c.id, %{status: :pass})
    end
  end

  defp check(%{kind: :png} = c, config) do
    {body, _content_type} = render(c.native <> "/format=png", c.source, config)
    File.write!(Path.join(@results, "#{c.id}.actual.png"), body)
    actual = Image.open!(body, access: :random, fail_on: :error)
    expected = Image.open!(fixture_path(c.id), access: :random, fail_on: :error)
    {threshold, budget} = c.tolerance

    unless PixelCompare.same_dims?(actual, expected) do
      fail_case(
        c.id,
        "dimensions #{inspect(PixelCompare.dims(actual))} != imgproxy reference " <>
          inspect(PixelCompare.dims(expected))
      )
    end

    {actual, expected} = comparable(actual, expected)

    if VipsImage.bands(actual) != VipsImage.bands(expected) do
      fail_case(
        c.id,
        "#{VipsImage.bands(actual)} bands != imgproxy reference #{VipsImage.bands(expected)}"
      )
    end

    outliers = PixelCompare.outliers(actual, expected, threshold)
    max_delta = write_diff(c.id, actual, expected)
    metrics = %{outliers: outliers, threshold: threshold, budget: budget, max_delta: max_delta}

    if outliers > budget do
      fail_case(c.id, "#{outliers} band samples exceed Δ#{threshold}; budget #{budget}", metrics)
    else
      record(c.id, Map.put(metrics, :status, :pass))
    end
  end

  defp render(native, source, config) do
    response = conn(:get, "/#{native}/src/#{source}") |> ImagePipe.Plug.call(config)

    assert response.status == 200,
           "/#{native}/src/#{source}: status #{response.status}: #{response.resp_body}"

    [content_type] = Plug.Conn.get_resp_header(response, "content-type")
    {response.resp_body, content_type}
  end

  # imgproxy sometimes promotes a grayscale result to sRGB without changing its
  # values, so compare a 1- or 2-band output against an RGB(A) reference in sRGB.
  # Colour under fully transparent pixels is invisible, so alpha images compare
  # premultiplied.
  defp comparable(actual, expected) do
    actual =
      if VipsImage.bands(actual) < VipsImage.bands(expected) and
           VipsImage.interpretation(actual) == :VIPS_INTERPRETATION_B_W do
        {:ok, srgb} = Operation.colourspace(actual, :VIPS_INTERPRETATION_sRGB)
        srgb
      else
        actual
      end

    {premultiplied(actual), premultiplied(expected)}
  end

  defp premultiplied(image) do
    if Image.has_alpha?(image) do
      {:ok, premultiplied} = Operation.premultiply(image)
      {:ok, cast} = Operation.cast(premultiplied, VipsImage.format(image))
      cast
    else
      image
    end
  end

  # Writes the difference amplified ×8 and returns its maximum, both in 8-bit
  # levels like `PixelCompare` (16-bit samples are divided by 257).
  defp write_diff(id, actual, expected) do
    levels = if VipsImage.format(actual) == :VIPS_FORMAT_USHORT, do: 257.0, else: 1.0
    {:ok, delta} = Operation.subtract(actual, expected)
    {:ok, delta} = Operation.abs(delta)
    {:ok, delta} = Operation.linear(delta, [1.0 / levels], [0.0])
    {:ok, {max_delta, _position}} = Operation.max(delta)
    max_delta = Float.round(max_delta, 1)
    {:ok, amplified} = Operation.linear(delta, [8.0], [0.0])
    {:ok, amplified} = Operation.cast(amplified, :VIPS_FORMAT_UCHAR)
    Image.write!(amplified, Path.join(@results, "#{id}.diff.png"))
    max_delta
  end

  # Every case records its result for `mix imgproxy.report`, passing or not.
  defp record(id, result),
    do: File.write!(Path.join(@results, "#{id}.result"), :erlang.term_to_binary(result))

  defp fail_case(id, message, metrics \\ %{}) do
    record(id, Map.merge(metrics, %{status: :fail, message: message}))
    flunk("#{id}: #{message}. Output written to #{@results}/")
  end

  defp fixture_path(id), do: Path.join(@fixtures, "#{id}.png")

  defp file_sha256(path),
    do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
end
