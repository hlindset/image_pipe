defmodule ImagePipe.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Color

  defmodule CaptureImage do
    def stream!(_image, opts) do
      send(Process.get(:test_pid), {:stream_opts, opts})
      ["encoded"]
    end
  end

  defmodule RaisingStreamImage do
    def stream!(_image, _opts) do
      raise "forced stream failure"
    end
  end

  test "stream_output returns an enumerable and content type" do
    {:ok, image} = Image.new(1, 1)
    Process.put(:test_pid, self())

    resolved_output = %Resolved{
      format: :webp,
      quality: {:quality, 80},
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source
    }

    assert {:ok, stream, "image/webp", _meta} =
             Encoder.stream_output(image, resolved_output, image_module: CaptureImage)

    assert Enum.to_list(stream) == ["encoded"]
    assert_received {:stream_opts, [suffix: ".webp", quality: 80]}
  end

  test "stream_output normalizes stream construction exceptions as encode errors" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %RuntimeError{message: "forced stream failure"}, stacktrace}} =
             Encoder.stream_output(
               image,
               %Resolved{
                 format: :jpeg,
                 quality: :default,
                 response_headers: [],
                 strip_metadata: false,
                 keep_copyright: true,
                 color_profile: :preserve_source
               },
               image_module: RaisingStreamImage
             )

    assert is_list(stacktrace)
  end

  test "stream_output flattens an alpha image onto the resolved flatten_background for a non-alpha format" do
    {:ok, image} = Image.new(8, 8, color: [0, 0, 0, 0], bands: 4)
    {:ok, red} = Color.rgb(255, 0, 0)

    resolved = %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source,
      flatten_background: red
    }

    assert {:ok, stream, "image/jpeg", _meta} = Encoder.stream_output(image, resolved, [])

    decoded =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Image.open!(access: :random, fail_on: :error)

    refute Image.has_alpha?(decoded)
    # Fully transparent source flattened onto the resolved red background; JPEG is
    # lossy so allow a small tolerance.
    assert [r, g, b] = Image.get_pixel!(decoded, 4, 4)
    assert r > 250 and g < 5 and b < 5
  end

  test "stream_output blends a semi-transparent image onto the default flatten_background for a non-alpha format" do
    {:ok, image} = Image.new(8, 8, color: [255, 0, 0, 128], bands: 4)

    resolved = %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source
      # flatten_background omitted -> defaults to opaque white
    }

    assert {:ok, stream, "image/jpeg", _meta} = Encoder.stream_output(image, resolved, [])

    decoded =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Image.open!(access: :random, fail_on: :error)

    refute Image.has_alpha?(decoded)
    # ~50% red composited onto white: out = fg*a + bg*(1-a) ≈ [255, 127, 127].
    assert [r, g, b] = Image.get_pixel!(decoded, 4, 4)
    assert r > 245
    assert_in_delta g, 128, 12
    assert_in_delta b, 128, 12
  end

  test "stream_output leaves an alpha image untouched when the format carries alpha" do
    {:ok, image} = Image.new(8, 8, color: [10, 20, 30, 0], bands: 4)

    resolved = %Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source
      # default white flatten_background must be ignored for an alpha-capable format
    }

    assert {:ok, stream, "image/png", _meta} = Encoder.stream_output(image, resolved, [])

    decoded =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Image.open!(access: :random, fail_on: :error)

    # PNG carries alpha, so the transparent band is preserved (not flattened to white).
    assert Image.has_alpha?(decoded)
    assert [_r, _g, _b, alpha] = Image.get_pixel!(decoded, 4, 4)
    assert alpha == 0
  end

  @fixture "test/support/image_pipe/test/imgproxy_differential/sources/high_freq.jpg"

  defp search_resolved do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  describe "encode_to_buffer/3" do
    test "encodes to an in-memory binary; lower quality yields fewer bytes" do
      {:ok, img} = Image.open(@fixture)

      assert {:ok, q20} = Encoder.encode_to_buffer(img, search_resolved(), 20)
      assert {:ok, q90} = Encoder.encode_to_buffer(img, search_resolved(), 90)
      assert is_binary(q20)
      assert is_binary(q90)
      assert byte_size(q20) < byte_size(q90)
    end
  end

  describe "encode_jxl_distance/3" do
    @tag :jxl
    test "jxl distance suffix encodes a valid JXL" do
      {:ok, img} = Image.new(64, 64, color: [100, 110, 120])
      assert {:ok, bin} = Encoder.encode_jxl_distance(img, 1.5, nil)
      assert {:ok, decoded} = Image.from_binary(bin)
      assert Image.width(decoded) == 64
    end
  end

  describe "jxl_effort threading" do
    @tag :jxl
    test "jxl_effort changes encoded bytes; effort 7 matches the no-effort baseline" do
      {:ok, image} = Image.new(64, 64, color: [100, 110, 120])

      resolved = fn effort ->
        %Resolved{
          format: :jpeg_xl,
          quality: {:quality, 80},
          response_headers: [],
          strip_metadata: true,
          keep_copyright: true,
          color_profile: :strip,
          jxl_effort: effort
        }
      end

      {:ok, effort7} = Encoder.encode_to_buffer(image, resolved.(7), 80)
      {:ok, no_effort} = Encoder.encode_to_buffer(image, resolved.(nil), 80)
      {:ok, effort4} = Encoder.encode_to_buffer(image, resolved.(4), 80)

      assert effort7 == no_effort
      refute effort7 == effort4
    end
  end

  test "stream_output returns nil meta on the non-search (lazy) path" do
    {:ok, image} = Image.new(64, 64, color: [100, 150, 200])

    resolved = %Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :srgb
    }

    assert {:ok, _stream, "image/png", nil} = Encoder.stream_output(image, resolved, [])
  end

  describe "stream_output/3 (search path)" do
    test "honors a max_bytes ceiling (best-effort)" do
      {:ok, img} = Image.open(@fixture)
      resolved = %{search_resolved() | max_bytes: 200_000}

      {:ok, stream, mime, _meta} = Encoder.stream_output(img, resolved, [])
      body = stream |> Enum.to_list() |> IO.iodata_to_binary()
      assert mime == "image/jpeg"
      assert byte_size(body) <= 200_000
    end

    test "runs an ssim2 search and produces a decodable body" do
      {:ok, img} = Image.open(@fixture)

      rs = %ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2{
        target: 85.0,
        min_quality: 50,
        max_quality: 90,
        allowed_error: 1.0
      }

      resolved = %{search_resolved() | quality_search: rs}

      {:ok, stream, _mime, _meta} = Encoder.stream_output(img, resolved, [])
      body = stream |> Enum.to_list() |> IO.iodata_to_binary()
      assert {:ok, _decoded} = Image.from_binary(body)
    end
  end
end
