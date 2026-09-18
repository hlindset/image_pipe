defmodule ImagePipe.Native.BlurhashTest do
  # Real fetch/decode through a Plug-backed origin per case — mirrors
  # `pipeline_pixel_test.exs`.
  use ExUnit.Case, async: false

  alias ImagePipe.Decode
  alias ImagePipe.Native.Parser
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.State

  # A plain 3200x2400 landscape JPEG — large enough to exercise JPEG
  # shrink-on-load, matching the fixture size pinned in
  # `DecodePlannerRequestTest` ("terminal_reduction alone informs load
  # shrink" -> shrink 8 for a {32,32} terminal frame).
  defmodule LargeLandscapeOrigin do
    @moduledoc false
    def call(conn, _opts) do
      {:ok, base} = Image.new(3200, 2400, color: [90, 100, 110])
      body = Image.write!(base, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp source_opts(origin, extra \\ []) do
    Source.validate_config!(
      Keyword.merge(
        [
          sources: [
            path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
          ],
          max_body_bytes: 10_000_000,
          max_input_pixels: 40_000_000,
          auto_rotate?: true
        ],
        extra
      )
    )
  end

  defp resolved(opts) do
    {:ok, resolved} = Source.resolve(%SourcePath{segments: ["images", "x.jpg"]}, opts, [])
    resolved
  end

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp parse!(segments) do
    source = "test"

    lexed = %{
      segments: Enum.map(segments, &seg/1),
      source: {:src, source, {0, byte_size(source)}}
    }

    assert {:ok, request} = Parser.parse(lexed, [])
    request
  end

  defp run_reduced(origin, %Request{} = request, extra \\ []) do
    opts = source_opts(origin, extra)

    Decode.with_image(
      resolved(opts),
      opts,
      &Executor.decode_request(request, &1),
      fn state, _geometry ->
        with {:ok, state} <- Executor.execute(state, request, opts) do
          Executor.reduce_terminal(state, request.output, opts)
        end
      end
    )
  end

  test "output=blurhash with no resize on a large jpeg gets shrink > 1 on decode (#377 tied to the wire)" do
    request = parse!(["output=blurhash"])
    opts = source_opts(LargeLandscapeOrigin)

    result =
      Decode.with_image(
        resolved(opts),
        opts,
        &Executor.decode_request(request, &1),
        fn state, _geometry -> {:ok, state} end
      )

    assert {:ok, %State{decode_shrink: %{w: w, h: h}}} = result
    assert w > 1.0
    assert h > 1.0
  end

  test "reduce_terminal contain-fits the pipeline output to the 32x32 working frame" do
    request = parse!(["output=blurhash"])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)

    assert Image.width(image) <= 32
    assert Image.height(image) <= 32
    # 3200x2400 (4:3 landscape) contain-fit within a 32x32 box -> 32x24.
    assert {Image.width(image), Image.height(image)} == {32, 24}
  end

  test "reduce_terminal is a no-op for the plain image terminal" do
    request = parse!([])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)
    assert {Image.width(image), Image.height(image)} == {3200, 2400}
  end

  test "a resize=200x150,fit=contain group still reduces further to the terminal frame" do
    request = parse!(["w=200", "h=150", "output=blurhash"])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)
    assert {Image.width(image), Image.height(image)} == {32, 24}
  end

  test "compute/1 produces a plausibly-shaped blurhash for the reduced pipeline output" do
    request = parse!(["output=blurhash"])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)
    assert {:ok, hash} = Blurhash.compute(image)
    assert hash =~ ~r/^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]+$/
    assert String.length(hash) == 28
  end
end
