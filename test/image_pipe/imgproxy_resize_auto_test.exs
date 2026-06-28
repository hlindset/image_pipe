defmodule ImagePipe.ImgproxyResizeAutoTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Request.Runner
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Source.Resolved

  defmodule GeneratedSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("test builds resolved sources directly")

    @impl ImagePipe.Source
    def fetch(%ImagePipe.Source.Resolved{fetch: source}, _opts, _runtime_opts) do
      {width, height} = source
      {:ok, image} = Image.new(width, height, color: :white)
      body = Image.write!(image, :memory, suffix: ".png")

      {:ok, %ImagePipe.Source.Response{stream: [body]}}
    end
  end

  defp parse_plan!(path) do
    conn = conn(:get, path)
    assert {:ok, plan} = Imgproxy.parse(conn, [])
    {conn, plan}
  end

  defp assert_auto_resize_dimensions(source, target, expected) do
    path = auto_resize_path(source, target)
    {conn, plan} = parse_plan!(path)
    resolved_source = resolved_source(source)

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, _response, %CacheHeaders{}}} =
             run(
               conn,
               plan,
               resolved_source,
               sources: %{path: {GeneratedSourceAdapter, []}}
             )

    body = collect_prepared_stream(prepared)
    assert {:ok, image} = Image.open(body, access: :random, fail_on: :error)
    assert {Image.width(image), Image.height(image)} == expected
  end

  defp collect_prepared_stream(%PreparedStream{} = prepared) do
    [prepared.first_chunk]
    |> collect_prepared_stream(prepared)
    |> IO.iodata_to_binary()
  end

  defp collect_prepared_stream(chunks, %PreparedStream{} = prepared) do
    case prepared.next.() do
      {:chunk, chunk} -> collect_prepared_stream([chunks, chunk], prepared)
      :done -> chunks
    end
  end

  defp auto_resize_path(source, {target_width, target_height}) do
    "/_/rt:auto/w:#{target_width}/h:#{target_height}/f:jpeg/plain/generated/#{source_basename(source)}"
  end

  defp source_basename({width, height}), do: "#{width}x#{height}.png"

  defp source_identity(source),
    do: [
      kind: :path,
      adapter: :path,
      root: "generated",
      path: ["generated", source_basename(source)]
    ]

  defp resolved_source(source) do
    %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: source_identity(source),
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
      fetch: source
    }
  end

  defp run(conn, plan, resolved_source, opts) do
    Runner.run(conn, plan, resolved_source, empty_cache_headers(), request_opts(opts))
  end

  defp request_opts(opts) do
    Keyword.merge(
      [
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000,
        max_result_width: 8_192,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      ],
      opts
    )
  end

  defp empty_cache_headers do
    %CacheHeaders{representation_headers: [], headers: [], etag: nil}
  end

  test "1. request-level resize:auto from 300x200 to 100x50 returns 100x50" do
    assert_auto_resize_dimensions({300, 200}, {100, 50}, {100, 50})
  end

  test "2. request-level resize:auto from 300x200 to 50x100 returns 50x33" do
    assert_auto_resize_dimensions({300, 200}, {50, 100}, {50, 33})
  end

  test "3. request-level resize:auto from 100x100 to 50x50 returns 50x50" do
    assert_auto_resize_dimensions({100, 100}, {50, 50}, {50, 50})
  end

  test "4. request-level resize:auto from 100x100 to 50x80 returns 50x50" do
    assert_auto_resize_dimensions({100, 100}, {50, 80}, {50, 50})
  end

  # #233: imgproxy buckets fill-vs-fit by the sign of width−height, with square
  # (diff == 0) sharing the non-negative (landscape) bucket. So square↔landscape
  # pairs fill (cover + result-crop), not fit. (processing/prepare.go:88-97)

  test "5. resize:auto square source 100x100 into landscape 100x50 fills to 100x50" do
    assert_auto_resize_dimensions({100, 100}, {100, 50}, {100, 50})
  end

  test "6. resize:auto landscape source 200x100 into square 50x50 fills to 50x50" do
    assert_auto_resize_dimensions({200, 100}, {50, 50}, {50, 50})
  end

  test "7. resize:auto portrait source 100x200 into square 50x50 fits to 25x50" do
    assert_auto_resize_dimensions({100, 200}, {50, 50}, {25, 50})
  end

  test "host jxl_options lands on Plan.Output.encoder_options; unset stays empty" do
    conn = conn(:get, "/_/f:jxl/plain/images/cat.jpg")

    assert {:ok, plan} =
             Imgproxy.parse(conn,
               imgproxy: [jxl_options: %ImagePipe.Plan.Output.JxlOptions{effort: 4}]
             )

    assert plan.output.encoder_options == %{jpeg_xl: %ImagePipe.Plan.Output.JxlOptions{effort: 4}}

    assert {:ok, plan_default} = Imgproxy.parse(conn(:get, "/_/f:jxl/plain/images/cat.jpg"), [])
    assert plan_default.output.encoder_options == %{}
  end
end
