defmodule ImagePipe.Parser.TwicPicsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Parser.TwicPics
  alias ImagePipe.Plan

  test "parse/2 returns a Plan for a valid twic request" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/resize=100/output=avif")

    assert {:ok, %Plan{output: %Plan.Output{mode: {:explicit, :avif}}}} = TwicPics.parse(conn, [])
  end

  test "parse/2 returns an error for an unsupported transform" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/zoom=2")
    assert {:error, {:unsupported_transform, "zoom"}} = TwicPics.parse(conn, [])
  end

  test "handle_error/2 sends a 400 text response" do
    conn = conn(:get, "/x?twic=v1/zoom=2")
    result = TwicPics.handle_error(conn, {:error, {:unsupported_transform, "zoom"}})

    assert result.status == 400
    assert get_resp_header(result, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "validate_options!/1 resolves the :twicpics neutral config into the opts" do
    opts = TwicPics.validate_options!([])
    assert Keyword.fetch!(opts[:twicpics], :quality) == 80
    assert Keyword.fetch!(opts[:twicpics], :strip_metadata) == true
  end

  test "validate_options!/1 raises on a non-list :twicpics value" do
    assert_raise ArgumentError, ~r/invalid twicpics options/, fn ->
      TwicPics.validate_options!(twicpics: :nope)
    end
  end

  describe "neutral config" do
    test "accepts and resolves a neutral quality key" do
      opts = TwicPics.validate_options!(twicpics: [quality: 90])
      assert Keyword.fetch!(opts[:twicpics], :quality) == 90
    end

    test "rejects an unknown key" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        TwicPics.validate_options!(twicpics: [bogus: 1])
      end
    end

    test "raises at init for autoquality :size with no target" do
      assert_raise ArgumentError, ~r/autoquality|invalid twicpics/, fn ->
        TwicPics.validate_options!(twicpics: [autoquality_method: :size])
      end
    end
  end
end
