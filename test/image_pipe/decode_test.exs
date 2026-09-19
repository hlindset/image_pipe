defmodule ImagePipe.DecodeTest do
  # Real fetch/decode through a Plug-backed origin per case — keep it serial.
  use ExUnit.Case, async: false

  alias ImagePipe.API.Parser
  alias ImagePipe.Decode
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  # ── Origin plugs ─────────────────────────────────────────────────────────

  defmodule OriginImage do
    @moduledoc false
    def call(conn, _opts) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule NotFoundOrigin do
    @moduledoc false
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "not found")
  end

  defmodule CorruptOrigin do
    @moduledoc false
    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "this is not an image")
    end
  end

  defmodule GifOrigin do
    @moduledoc false
    # A minimal valid 1x1 GIF89a — header-detectable as :gif, so it exercises
    # the gate_detected/1 rejection branch (not a corrupt/unopenable body).
    @gif_1x1 Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBTAA7")

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/gif")
      |> Plug.Conn.send_resp(200, @gif_1x1)
    end
  end

  defmodule OrientedOrigin do
    @moduledoc false
    # An 800x600 (landscape) JPEG tagged EXIF orientation 6 (a 90 degree
    # turn), so storage dims are 800x600 but auto-rotated display dims are
    # 600x800 (portrait) — display != storage.
    def call(conn, _opts) do
      {:ok, base} = Image.new(800, 600, color: [120, 130, 140])
      body = base |> Image.set_orientation!(6) |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule LargeJpegOrigin do
    @moduledoc false
    # A 4096x2048 solid-colour JPEG, sized so a half-size resize target hits
    # a clean jpeg block shrink of exactly 2 (libjpeg's power-of-two floor).
    def call(conn, _opts) do
      {:ok, base} = Image.new(4096, 2048, color: [50, 60, 70])
      body = Image.write!(base, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp source_opts(origin, extra \\ []) do
    Source.validate_config!(
      Keyword.merge(
        [
          sources: [
            path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
          ],
          max_body_bytes: 10_000_000,
          max_input_pixels: 40_000_000
        ],
        extra
      )
    )
  end

  defp resolved(opts) do
    {:ok, resolved} = Source.resolve(%SourcePath{segments: ["images", "x.jpg"]}, opts, [])
    resolved
  end

  defp request(segments \\ []) do
    source = "images/x.jpg"

    lexed = %{
      segments: Enum.map(segments, &{&1, {0, byte_size(&1)}}),
      source: {:src, source, {0, byte_size(source)}}
    }

    assert {:ok, %Request{} = request} = Parser.parse(lexed, [])
    request
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  test "seeds state and source geometry for transform execution" do
    opts = source_opts(OriginImage)
    request = request()

    result =
      Decode.with_image(resolved(opts), request, opts, fn state, geometry ->
        {:ok, {state, geometry}}
      end)

    assert {:ok, {%State{} = state, %SourceGeometry{} = geometry}} = result
    assert geometry.source_format == :jpeg
    assert geometry.storage_dimensions == {Image.width(state.image), Image.height(state.image)}
    assert geometry.display_dimensions == geometry.storage_dimensions
    assert PendingOrientation.identity?(geometry.pending_orientation)
    assert state.pending_orientation == geometry.pending_orientation
    assert state.decode_shrink == nil
    assert state.source_dimensions == nil

    assert {:ok, %State{} = resized} =
             Transform.run(state, %ExecutableResize{width: 100, height: 100})

    assert Image.width(resized.image) == 100
  end

  test "oversized header pixels short-circuit as {:error, {:input_limit, _}}" do
    opts = source_opts(OriginImage, max_input_pixels: 1000)
    request = request()

    result =
      Decode.with_image(resolved(opts), request, opts, fn _state, _geometry ->
        flunk("fun must not run past the pixel-limit gate")
      end)

    assert {:error, {:input_limit, {:too_many_input_pixels, pixel_count, 1000}}} = result
    assert pixel_count > 1000
  end

  test "a corrupt body normalizes to {:error, {:decode, _}}" do
    opts = source_opts(CorruptOrigin)
    request = request()

    result =
      Decode.with_image(resolved(opts), request, opts, fn _state, _geometry ->
        flunk("fun must not run on a decode failure")
      end)

    assert {:error, {:decode, _reason}} = result
  end

  test "an unsupported source format (gif) normalizes to {:error, {:decode, _}}, not a bare :unsupported_source_format tag" do
    opts = source_opts(GifOrigin)
    request = request()

    result =
      Decode.with_image(resolved(opts), request, opts, fn _state, _geometry ->
        flunk("fun must not run on a rejected source format")
      end)

    assert {:error, {:decode, {:unsupported_source_format, :gif}}} = result
  end

  test "a source fetch failure normalizes to {:error, {:source, _}}" do
    opts = source_opts(NotFoundOrigin)
    request = request()

    result =
      Decode.with_image(resolved(opts), request, opts, fn _state, _geometry ->
        flunk("fun must not run on a source fetch failure")
      end)

    assert {:error, {:source, {:bad_status, 404}}} = result
  end

  test "an auto-oriented request exposes header-open display geometry" do
    opts = source_opts(OrientedOrigin)
    request = request()

    assert {:ok, {%State{}, %SourceGeometry{} = geometry}} =
             Decode.with_image(resolved(opts), request, opts, fn state, geometry ->
               {:ok, {state, geometry}}
             end)

    assert geometry.storage_dimensions == {800, 600}
    assert geometry.display_dimensions == {600, 800}
    assert geometry.pending_orientation.exif_angle == 90
    refute PendingOrientation.identity?(geometry.pending_orientation)
  end

  test "orient=none seeds a non-rotating pending orientation on the same EXIF-oriented source" do
    opts = source_opts(OrientedOrigin)
    request = request(["orient=none"])

    assert {:ok, {%State{} = state, %SourceGeometry{} = geometry}} =
             Decode.with_image(resolved(opts), request, opts, fn state, geometry ->
               {:ok, {state, geometry}}
             end)

    assert geometry.storage_dimensions == {800, 600}
    assert geometry.display_dimensions == {800, 600}
    assert PendingOrientation.identity?(geometry.pending_orientation)
    assert state.pending_orientation == geometry.pending_orientation
  end

  test "shrink actually applied: a half-size resize_target halves the loaded dims and sets decode_shrink" do
    opts = source_opts(LargeJpegOrigin)
    request = request(["w=2048", "h=1024"])

    assert {:ok, %State{} = state} =
             Decode.with_image(resolved(opts), request, opts, fn state, _geometry ->
               {:ok, state}
             end)

    assert Image.width(state.image) == 2048
    assert Image.height(state.image) == 1024
    assert state.decode_shrink == %{w: 2.0, h: 2.0}
    assert state.source_dimensions == {4096, 2048}
  end
end
