defmodule ImagePipe.Response.ConditionalTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias ImagePipe.Response.Conditional

  @etag ~s("ipr1-abc123")

  defp conn_with(method \\ :get, headers) do
    conn = conn(method, "/x")
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  describe "not_modified?/2" do
    test "exact strong tag match" do
      conn = conn_with([{"if-none-match", @etag}])
      assert Conditional.not_modified?(conn, @etag) == true
    end

    test "weak W/ prefix on the request tag still matches the strong stored etag" do
      conn = conn_with([{"if-none-match", "W/" <> @etag}])
      assert Conditional.not_modified?(conn, @etag) == true
    end

    test "multi-tag list: matches when any listed tag matches" do
      conn = conn_with([{"if-none-match", ~s("nope-1", #{@etag}, "nope-2")}])
      assert Conditional.not_modified?(conn, @etag) == true
    end

    test "multi-tag list: no match when none of the listed tags match" do
      conn = conn_with([{"if-none-match", ~s("nope-1", "nope-2")}])
      assert Conditional.not_modified?(conn, @etag) == false
    end

    test "bare * wildcard does NOT match here (pre-fetch, nothing proven yet)" do
      conn = conn_with([{"if-none-match", "*"}])
      assert Conditional.not_modified?(conn, @etag) == false
    end

    test "* mixed with explicit tags does NOT match here either" do
      conn = conn_with([{"if-none-match", ~s(*, #{@etag})}])
      assert Conditional.not_modified?(conn, @etag) == false
    end

    test "no If-None-Match header: no match" do
      conn = conn_with([])
      assert Conditional.not_modified?(conn, @etag) == false
    end

    test "different etag: no match" do
      conn = conn_with([{"if-none-match", ~s("other-etag")}])
      assert Conditional.not_modified?(conn, @etag) == false
    end

    test "nil etag: no match regardless of header" do
      conn = conn_with([{"if-none-match", @etag}])
      assert Conditional.not_modified?(conn, nil) == false
    end

    test "POST request: never matches even with an exact tag" do
      conn = conn_with(:post, [{"if-none-match", @etag}])
      assert Conditional.not_modified?(conn, @etag) == false
    end

    test "HEAD request: exact tag matches" do
      conn = conn_with(:head, [{"if-none-match", @etag}])
      assert Conditional.not_modified?(conn, @etag) == true
    end
  end

  describe "if_none_match_wildcard?/1" do
    test "bare * is the wildcard" do
      conn = conn_with([{"if-none-match", "*"}])
      assert Conditional.if_none_match_wildcard?(conn) == true
    end

    test "* mixed with explicit tags collapses to the wildcard" do
      conn = conn_with([{"if-none-match", ~s(#{@etag}, *)}])
      assert Conditional.if_none_match_wildcard?(conn) == true
    end

    test "exact tag alone is not the wildcard" do
      conn = conn_with([{"if-none-match", @etag}])
      assert Conditional.if_none_match_wildcard?(conn) == false
    end

    test "weak tag alone is not the wildcard" do
      conn = conn_with([{"if-none-match", "W/" <> @etag}])
      assert Conditional.if_none_match_wildcard?(conn) == false
    end

    test "multi-tag list without * is not the wildcard" do
      conn = conn_with([{"if-none-match", ~s("a", "b")}])
      assert Conditional.if_none_match_wildcard?(conn) == false
    end

    test "no If-None-Match header is not the wildcard" do
      conn = conn_with([])
      assert Conditional.if_none_match_wildcard?(conn) == false
    end
  end
end
