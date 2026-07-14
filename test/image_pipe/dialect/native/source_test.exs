defmodule ImagePipe.Dialect.Native.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Native.Source
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.URL

  describe "translate/2 — relative path sources" do
    test "single segment splits to one-element segment list" do
      assert {:ok, %Path{segments: ["cat.jpg"]}} = Source.translate("cat.jpg", [])
    end

    test "multi-segment path splits on / in order" do
      assert {:ok, %Path{segments: ["images", "nested", "cat.jpg"]}} =
               Source.translate("images/nested/cat.jpg", [])
    end

    test "the decoded string is the source of truth — no further decoding happens" do
      # Task 4 already percent-decoded this once; a literal space here must
      # survive untouched, not be treated as still-encoded.
      assert {:ok, %Path{segments: ["my photo.jpg"]}} =
               Source.translate("my photo.jpg", [])
    end
  end

  describe "translate/2 — http(s) URL sources" do
    test "parses scheme, host, path, and query" do
      assert {:ok,
              %URL{
                scheme: :https,
                host: "example.com",
                port: 443,
                path: ["cat.jpg"],
                query: nil
              }} = Source.translate("https://example.com/cat.jpg", [])
    end

    test "the encoded-query example arrives already-decoded and splits into query" do
      # Raw path segment was `cat.jpg%3Fv%3D2`; Task 4 decodes it once to
      # `cat.jpg?v=2` before this module ever sees it.
      assert {:ok,
              %URL{
                scheme: :https,
                host: "example.com",
                path: ["cat.jpg"],
                query: "v=2"
              }} = Source.translate("https://example.com/cat.jpg?v=2", [])
    end

    test "http scheme is accepted with its own default port" do
      assert {:ok, %URL{scheme: :http, host: "example.com", port: 80}} =
               Source.translate("http://example.com/cat.jpg", [])
    end

    test "explicit non-default port is preserved" do
      assert {:ok, %URL{scheme: :https, host: "example.com", port: 8443}} =
               Source.translate("https://example.com:8443/cat.jpg", [])
    end

    test "root path (no path segments) yields an empty segment list" do
      assert {:ok, %URL{path: []}} = Source.translate("https://example.com", [])
      assert {:ok, %URL{path: []}} = Source.translate("https://example.com/", [])
    end

    test "multi-segment path" do
      assert {:ok, %URL{path: ["a", "b", "c.jpg"]}} =
               Source.translate("https://example.com/a/b/c.jpg", [])
    end

    test "host is lowercased" do
      assert {:ok, %URL{host: "example.com"}} =
               Source.translate("https://EXAMPLE.com/cat.jpg", [])
    end
  end

  describe "translate/2 — errors" do
    test "empty source is rejected" do
      assert {:error, {:invalid_source, _reason}} = Source.translate("", [])
    end

    test "a non-http(s) scheme is rejected" do
      assert {:error, {:invalid_source, _reason}} =
               Source.translate("ftp://example.com/cat.jpg", [])
    end

    test "an s3 scheme is rejected (scheme forms per host config are post-probe)" do
      assert {:error, {:invalid_source, _reason}} =
               Source.translate("s3://bucket/key.jpg", [])
    end

    test "a malformed http(s) authority (empty host) is rejected" do
      assert {:error, {:invalid_source, _reason}} = Source.translate("https:///cat.jpg", [])
    end

    test "userinfo (user:pass@) is rejected rather than silently dropped" do
      assert {:error, {:invalid_source, :userinfo_not_allowed}} =
               Source.translate("https://user:pass@example.com/x", [])
    end

    test "userinfo without a password is rejected" do
      assert {:error, {:invalid_source, :userinfo_not_allowed}} =
               Source.translate("https://user@example.com/x", [])
    end

    test "a fragment is rejected rather than silently dropped" do
      assert {:error, {:invalid_source, :fragment_not_allowed}} =
               Source.translate("https://example.com/x#frag", [])
    end

    test "positive control — a plain URL with query and no userinfo/fragment still succeeds" do
      assert {:ok, %URL{scheme: :https, host: "example.com", path: ["cat.jpg"], query: "v=2"}} =
               Source.translate("https://example.com/cat.jpg?v=2", [])
    end
  end
end
