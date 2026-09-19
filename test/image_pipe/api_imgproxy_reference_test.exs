defmodule ImagePipe.APIImgproxyReferenceTest do
  @moduledoc """
  Compact pixel references baked by upstream imgproxy and exercised through
  ImagePipe's API.

  See `test/support/image_pipe/test/imgproxy_reference/README.md` for immutable
  fixture provenance and the API translation of each upstream request.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Test.Differential.PixelCompare

  @sources "test/support/image_pipe/test/sources"
  @fixtures "test/support/image_pipe/test/imgproxy_reference"
  @tolerance 2
  @outlier_budget 64

  for {name, source, options} <- [
        {"crop_gravity_placement", "placement.png", "crop=120,90/anchor=top-left"},
        {"effects_chain_order_high_freq", "high_freq.jpg",
         "w=240/h=240/fit=contain/blur=2/sharpen=2/pixelate=8"},
        {"trim_equal_hv_border", "border_asym.png", "trim=auto/trim-symmetry=hv"}
      ] do
    @name name
    @source source
    @options options

    test "API #{name} stays within the retained imgproxy pixel reference" do
      actual = render(unquote(@source), unquote(@options))
      expected = Image.open!(Path.join(@fixtures, unquote(@name) <> ".png"), access: :random)

      assert PixelCompare.same_dims?(actual, expected),
             "dimensions #{inspect(PixelCompare.dims(actual))} != imgproxy reference " <>
               inspect(PixelCompare.dims(expected))

      outliers = PixelCompare.outliers(actual, expected, @tolerance)

      assert outliers <= @outlier_budget,
             "#{outliers} band samples exceed Δ#{@tolerance}; budget #{@outlier_budget}"
    end
  end

  defp render(source, options) do
    config =
      ImagePipe.Plug.init(
        sources: [path: {ImagePipe.Source.File, root: @sources, root_id: "imgproxy-reference"}]
      )

    response =
      conn(:get, "/#{options}/format=png/src/#{source}")
      |> ImagePipe.Plug.call(config)

    assert response.status == 200
    Image.open!(response.resp_body, access: :random, fail_on: :error)
  end
end
