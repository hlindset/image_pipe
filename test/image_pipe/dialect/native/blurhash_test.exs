defmodule ImagePipe.Dialect.Native.BlurhashTest do
  # Real fetch/decode through a Plug-backed origin per case — mirrors
  # `pipeline_pixel_test.exs`.
  use ExUnit.Case, async: false

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Native.Pipeline
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
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

  defp req(groups, output \\ %Output{terminal: :blurhash}) do
    %Request{groups: groups, output: output, source: "test"}
  end

  defp group(fields), do: struct!(Group, fields)

  defp run_reduced(origin, %Request{} = request, extra \\ []) do
    opts = source_opts(origin, extra)

    Decode.with_image(
      resolved(opts),
      opts,
      &Pipeline.decode_request(request, &1),
      fn state, geometry ->
        with {:ok, state} <- Pipeline.run(state, geometry, request, opts) do
          Pipeline.reduce_terminal(state, request, opts)
        end
      end
    )
  end

  test "output=blurhash with no resize on a large jpeg gets shrink > 1 on decode (#377 tied to the wire)" do
    request = req([group(%{})])
    opts = source_opts(LargeLandscapeOrigin)

    result =
      Decode.with_image(
        resolved(opts),
        opts,
        &Pipeline.decode_request(request, &1),
        fn state, _geometry -> {:ok, state} end
      )

    assert {:ok, %State{decode_shrink: %{w: w, h: h}}} = result
    assert w > 1.0
    assert h > 1.0
  end

  test "reduce_terminal contain-fits the pipeline output to the 32x32 working frame" do
    request = req([group(%{})])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)

    assert Image.width(image) <= 32
    assert Image.height(image) <= 32
    # 3200x2400 (4:3 landscape) contain-fit within a 32x32 box -> 32x24.
    assert {Image.width(image), Image.height(image)} == {32, 24}
  end

  test "reduce_terminal is a no-op for the plain image terminal" do
    request = req([group(%{})], %Output{terminal: :image})

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)
    assert {Image.width(image), Image.height(image)} == {3200, 2400}
  end

  test "a resize=200x150,fit=contain group still reduces further to the terminal frame" do
    request = req([group(%{resize: %{w: 200, h: 150, fit: :contain, enlarge: false}})])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)
    assert {Image.width(image), Image.height(image)} == {32, 24}
  end

  test "compute/1 produces a plausibly-shaped blurhash for the reduced pipeline output" do
    request = req([group(%{})])

    assert {:ok, %State{image: image}} = run_reduced(LargeLandscapeOrigin, request)
    assert {:ok, hash} = Blurhash.compute(image)
    assert hash =~ ~r/^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]+$/
    assert String.length(hash) == 28
  end
end
