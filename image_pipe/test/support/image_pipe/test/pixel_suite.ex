defmodule ImagePipe.Test.PixelSuite do
  @moduledoc """
  Shared harness for the whole-image suites (imgproxy references and goldens).

  A case renders a native request through `ImagePipe.Plug` and compares the
  decoded output with a committed fixture under a `{threshold, budget}`
  tolerance. Every case writes its output, an amplified difference image and
  its result to the suite's results directory, where
  `mix image_pipe.pixel_report` picks them up.

  A suite is a map with `:fixtures` and `:results` directories and a `:label`
  naming what the fixture is (`"imgproxy reference"`, `"golden"`).
  """
  use Boundary, top_level?: true, check: [out: false]

  import ExUnit.Assertions
  import Plug.Test

  alias ImagePipe.Test.Differential.PixelCompare
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/sources"

  @type suite :: %{fixtures: Path.t(), results: Path.t(), label: String.t()}

  @spec sources() :: Path.t()
  def sources, do: @sources

  @doc "Plug config serving the committed sources, with `alpha.png` as the `mark` watermark."
  def config(root_id) do
    ImagePipe.Plug.init(
      sources: [
        path: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: @sources, root_id: root_id]
        ]
      ],
      watermarks: %{mark: [source: "alpha.png"]}
    )
  end

  @doc "Empties the suite's results directory before a run."
  def reset!(%{results: results}) do
    File.rm_rf!(results)
    File.mkdir_p!(results)
  end

  @doc "The request path a case renders: `:png` cases add `format=png`."
  def request_path(%{kind: :png} = c), do: "/#{c.native}/format=png/src/#{c.source}"
  def request_path(c), do: "/#{c.native}/src/#{c.source}"

  @doc "Renders a case, returning the body and content type."
  def render(c, config) do
    response = conn(:get, request_path(c)) |> ImagePipe.Plug.call(config)

    assert response.status == 200,
           "#{request_path(c)}: status #{response.status}: #{response.resp_body}"

    [content_type] = Plug.Conn.get_resp_header(response, "content-type")
    {response.resp_body, content_type}
  end

  @doc """
  Compares a case's decoded output with its fixture PNG and records the
  result. `:png` cases render as PNG; any other kind renders its own format and
  compares decoded pixels.
  """
  def check_pixels(c, config, suite) do
    {body, _content_type} = render(c, config)
    actual = Image.open!(body, access: :random, fail_on: :error)
    Image.write!(actual, Path.join(suite.results, "#{c.id}.actual.png"))
    expected = Image.open!(fixture_path(suite, c.id), access: :random, fail_on: :error)
    {threshold, budget} = c.tolerance

    unless PixelCompare.same_dims?(actual, expected) do
      fail_case(
        suite,
        c.id,
        "dimensions #{inspect(PixelCompare.dims(actual))} != #{suite.label} " <>
          inspect(PixelCompare.dims(expected))
      )
    end

    {actual, expected} = comparable(actual, expected)

    if VipsImage.bands(actual) != VipsImage.bands(expected) do
      fail_case(
        suite,
        c.id,
        "#{VipsImage.bands(actual)} bands != #{suite.label} #{VipsImage.bands(expected)}"
      )
    end

    outliers = PixelCompare.outliers(actual, expected, threshold)
    max_delta = write_diff(suite, c.id, actual, expected)
    metrics = %{outliers: outliers, threshold: threshold, budget: budget, max_delta: max_delta}

    if outliers > budget do
      fail_case(
        suite,
        c.id,
        "#{outliers} band samples exceed Δ#{threshold}; budget #{budget}",
        metrics
      )
    else
      record(suite, c.id, Map.put(metrics, :status, :pass))
    end
  end

  @doc "Compares a lossy case's dimensions and content type with expected values."
  def check_lossy(c, config, suite, %{width: width, height: height, content_type: type}) do
    {body, content_type} = render(c, config)
    actual = Image.open!(body, access: :random, fail_on: :error)
    dims = {Image.width(actual), Image.height(actual)}

    cond do
      dims != {width, height} ->
        fail_case(suite, c.id, "dimensions #{inspect(dims)} != #{inspect({width, height})}")

      content_type != type ->
        fail_case(suite, c.id, "content type #{content_type} != #{type}")

      true ->
        record(suite, c.id, %{status: :pass})
    end
  end

  def fixture_path(%{fixtures: fixtures}, id), do: Path.join(fixtures, "#{id}.png")

  def file_sha256(path),
    do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  # imgproxy sometimes promotes a grayscale result to sRGB without changing its
  # values, so compare a 1- or 2-band output against an RGB(A) fixture in sRGB.
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
  defp write_diff(suite, id, actual, expected) do
    levels = if VipsImage.format(actual) == :VIPS_FORMAT_USHORT, do: 257.0, else: 1.0
    {:ok, delta} = Operation.subtract(actual, expected)
    {:ok, delta} = Operation.abs(delta)
    {:ok, delta} = Operation.linear(delta, [1.0 / levels], [0.0])
    {:ok, {max_delta, _position}} = Operation.max(delta)
    {:ok, amplified} = Operation.linear(delta, [8.0], [0.0])
    {:ok, amplified} = Operation.cast(amplified, :VIPS_FORMAT_UCHAR)
    Image.write!(amplified, Path.join(suite.results, "#{id}.diff.png"))
    Float.round(max_delta, 1)
  end

  # Every case records its result for `mix image_pipe.pixel_report`, passing or not.
  defp record(suite, id, result),
    do: File.write!(Path.join(suite.results, "#{id}.result"), :erlang.term_to_binary(result))

  defp fail_case(suite, id, message, metrics \\ %{}) do
    record(suite, id, Map.merge(metrics, %{status: :fail, message: message}))
    flunk("#{id}: #{message}. Output written to #{suite.results}/")
  end
end
