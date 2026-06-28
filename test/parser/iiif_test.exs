defmodule ImagePipe.Parser.IIIFTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Parser.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @opts [
    iiif: [
      resolver:
        {ImagePipe.Parser.IIIF.Resolver.Static,
         map: %{"abc" => %SourcePath{segments: ["beach.jpg"]}}}
    ]
  ]

  defp validated(opts), do: IIIF.validate_options!(opts)

  defp opts_with(extra), do: [iiif: Keyword.merge(@opts[:iiif], extra)]

  test "image request -> {:ok, %Plan{}} with explicit jpeg output" do
    assert {:ok, %Plan{render: :image, output: %{mode: {:explicit, :jpeg}}}} =
             IIIF.parse(conn(:get, "/abc/full/max/0/default.jpg"), validated(@opts))
  end

  test "bare identifier -> {:redirect, 303, absolute info.json}" do
    conn = %{conn(:get, "/abc") | script_name: ["iiif"]}
    assert {:redirect, 303, location} = IIIF.parse(conn, validated(@opts))
    assert String.ends_with?(location, "/iiif/abc/info.json")
  end

  test "unknown identifier -> {:error, :not_found}" do
    assert {:error, :not_found} =
             IIIF.parse(conn(:get, "/nope/full/max/0/default.jpg"), validated(@opts))
  end

  test "bad rotation token -> {:error, {:invalid_rotation, _}}" do
    assert {:error, {:invalid_rotation, "370"}} =
             IIIF.parse(conn(:get, "/abc/full/max/370/default.jpg"), validated(@opts))
  end

  test "handle_error: resolver miss -> 404; bad token -> 400" do
    assert IIIF.handle_error(conn(:get, "/"), {:error, :not_found}).status == 404
    assert IIIF.handle_error(conn(:get, "/"), {:error, {:invalid_size, "x"}}).status == 400
  end

  test "info request -> render plan with InfoRenderer + id param" do
    {:ok,
     %Plan{
       render: {:custom, ImagePipe.Parser.IIIF.InfoRenderer, params},
       output: nil,
       pipelines: []
     }} =
      IIIF.parse(conn(:get, "/abc/info.json"), validated(@opts))

    assert params.id =~ "/abc"
    assert params.offers != []
  end

  describe "max bounds option validation" do
    test "accepts max_width alone (does not raise)" do
      validated = IIIF.validate_options!(opts_with(max_width: 2000))
      assert Keyword.fetch!(Keyword.fetch!(validated, :iiif), :max_width) == 2000
    end

    test "accepts max_width + max_height" do
      validated = IIIF.validate_options!(opts_with(max_width: 2000, max_height: 1500))
      iiif = Keyword.fetch!(validated, :iiif)
      assert Keyword.fetch!(iiif, :max_width) == 2000
      assert Keyword.fetch!(iiif, :max_height) == 1500
    end

    test "accepts max_area alone" do
      validated = IIIF.validate_options!(opts_with(max_area: 3_000_000))
      assert Keyword.fetch!(Keyword.fetch!(validated, :iiif), :max_area) == 3_000_000
    end

    test "rejects max_height without max_width" do
      assert_raise ArgumentError, ~r/max_height requires max_width/, fn ->
        IIIF.validate_options!(opts_with(max_height: 1500))
      end
    end

    test "rejects a non-positive bound (NimbleOptions)" do
      assert_raise NimbleOptions.ValidationError, fn ->
        IIIF.validate_options!(opts_with(max_width: 0))
      end
    end
  end

  describe "neutral config" do
    test "accepts and resolves a neutral quality key" do
      iiif = Keyword.fetch!(IIIF.validate_options!(opts_with(quality: 90)), :iiif)
      assert Keyword.fetch!(iiif, :quality) == 90
      assert Keyword.fetch!(iiif, :tile_size) == 512
    end

    test "auto_rotate is now a neutral key (honored, default true)" do
      iiif = Keyword.fetch!(IIIF.validate_options!(@opts), :iiif)
      assert Keyword.fetch!(iiif, :auto_rotate) == true

      iiif2 = Keyword.fetch!(IIIF.validate_options!(opts_with(auto_rotate: false)), :iiif)
      assert Keyword.fetch!(iiif2, :auto_rotate) == false
    end

    test "rejects an unknown dialect key" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        IIIF.validate_options!(opts_with(bogus: 1))
      end
    end

    test "raises at init for autoquality :size with no target" do
      assert_raise ArgumentError, ~r/autoquality/, fn ->
        IIIF.validate_options!(opts_with(autoquality_method: :size))
      end
    end

    test "raises on a non-keyword :iiif value" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        IIIF.validate_options!(iiif: :nope)
      end
    end
  end
end

defmodule ImagePipe.Parser.IIIF.CORSTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias ImagePipe.Parser.IIIF.CORS

  test "OPTIONS -> 200 with CORS headers and halted" do
    conn =
      conn(:options, "/abc/full/max/0/default.jpg")
      |> CORS.call(CORS.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET, OPTIONS"]
    assert conn.halted
  end

  test "GET -> conn has before_send callback that adds Allow-Origin" do
    conn =
      conn(:get, "/abc/full/max/0/default.jpg")
      |> CORS.call(CORS.init([]))

    refute conn.halted

    # Trigger the before_send callbacks by sending a response
    conn = Plug.Conn.send_resp(conn, 200, "ok")
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
end
