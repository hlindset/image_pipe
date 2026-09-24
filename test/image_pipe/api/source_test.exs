defmodule ImagePipe.API.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Plug.Config
  alias ImagePipe.Source.Parser, as: Source

  @foobar_translator ImagePipe.SourceTest.FoobarTranslator

  describe "translate/2 — relative path sources" do
    test "an optional leading slash resolves to the same root-relative path" do
      assert Source.translate("/images/cat.jpg", []) == Source.translate("images/cat.jpg", [])
      assert {:error, {:invalid_source, :empty_source}} = Source.translate("/", [])
      assert {:ok, %Path{segments: ["", "", "cat.jpg"]}} = Source.translate("//cat.jpg", [])
      assert {:ok, %Path{}} = Source.translate("/https://example.com/cat.jpg", [])
    end

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

    test "inner URL path escapes decode once before the HTTP adapter re-encodes them" do
      assert {:ok,
              %URL{
                path: ["images", "my photo#1%done.jpg"],
                query: "token=a%26b%3Dc"
              }} =
               Source.translate(
                 "https://example.com/images/my%20photo%231%25done.jpg?token=a%26b%3Dc",
                 []
               )
    end

    test "escaped path separators stay inside their URL path segment" do
      assert {:ok, %URL{path: ["images", "nested/cat.jpg"]}} =
               Source.translate("https://example.com/images/nested%2Fcat.jpg", [])
    end

    test "preserves empty inner URL path components" do
      assert {:ok, %URL{path: ["images", "", "cat.jpg", ""]}} =
               Source.translate("https://example.com/images//cat.jpg/", [])

      assert {:ok, %URL{path: ["", "cat.jpg"]}} =
               Source.translate("https://example.com//cat.jpg", [])
    end

    test "host is lowercased" do
      assert {:ok, %URL{host: "example.com"}} =
               Source.translate("https://EXAMPLE.com/cat.jpg", [])
    end
  end

  describe "translate/2 — S3 object sources" do
    test "maps the bucket, opaque key, and decoded revision to an object source" do
      assert {:ok,
              %Object{
                adapter: :s3,
                scope: "bucket",
                key: "images/my photo#1%done.jpg",
                revision: "version=a&b=c"
              }} =
               Source.translate(
                 "s3://bucket/images/my%20photo%231%25done.jpg?version=a%26b%3Dc",
                 []
               )
    end

    test "preserves empty object-key components" do
      assert {:ok, %Object{key: "images//cat.jpg/"}} =
               Source.translate("s3://bucket/images//cat.jpg/", [])

      assert {:ok, %Object{key: "/cat.jpg"}} =
               Source.translate("s3://bucket//cat.jpg", [])
    end

    test "rejects object sources that cannot be represented by the S3 adapter" do
      for source <- [
            "s3:///cat.jpg",
            "s3://bucket",
            "s3://bucket/",
            "s3://user@bucket/cat.jpg",
            "s3://bucket:9000/cat.jpg",
            "s3://bucket/cat.jpg#fragment",
            "s3://bucket/cat%zz.jpg"
          ] do
        assert {:error, {:invalid_source, _reason}} = Source.translate(source, []), source
      end
    end
  end

  describe "translate/2 — configured source schemes" do
    test "routes an exact decoded source string through a configured translator" do
      source = "foobar://asset/cat%20one.jpg"

      assert {:ok, %Object{adapter: :foobar, key: ^source}} =
               Source.translate(source,
                 source_schemes: %{"foobar" => {@foobar_translator, color: "blue"}}
               )

      assert_receive {:foobar_translate, ^source}
    end

    test "normalizes callback failures without exposing callback reasons" do
      source = "broken://asset/cat.jpg"

      assert Source.translate(source,
               source_schemes: %{"broken" => {ImagePipe.Source.Parser, []}}
             ) == {:error, {:invalid_source, {:source_scheme_error, "broken"}}}
    end

    test "built-in source schemes cannot be replaced by configured translators" do
      config = %{"https" => {@foobar_translator, []}, "s3" => {@foobar_translator, []}}

      assert {:ok, %URL{}} =
               Source.translate("https://example.com/cat.jpg", source_schemes: config)

      assert {:ok, %Object{adapter: :s3}} =
               Source.translate("s3://bucket/cat.jpg", source_schemes: config)

      refute_received {:foobar_translate, _source}
    end
  end

  describe "source_schemes configuration" do
    test "accepts canonical custom schemes and supplies an empty default" do
      assert Config.validate!([])[:source_schemes] == %{}

      schemes = %{"ipfs+gateway" => {@foobar_translator, color: "blue"}}
      assert Config.validate!(source_schemes: schemes)[:source_schemes] == schemes
    end

    test "rejects built-in and non-canonical scheme names" do
      for scheme <- ["http", "https", "s3", "Foobar", "1foobar", "foo bar", ""] do
        assert_raise ArgumentError, fn ->
          Config.validate!(source_schemes: %{scheme => {@foobar_translator, []}})
        end
      end
    end

    test "rejects translators that are not callable with keyword options" do
      for source_schemes <- [
            %{"foobar" => {NotAModule, []}},
            %{"foobar" => {@foobar_translator, %{color: "blue"}}},
            %{"foobar" => :not_a_translator},
            [{"foobar", {@foobar_translator, []}}]
          ] do
        assert_raise ArgumentError, fn ->
          Config.validate!(source_schemes: source_schemes)
        end
      end
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

    test "a malformed http(s) authority (empty host) is rejected" do
      assert {:error, {:invalid_source, _reason}} = Source.translate("https:///cat.jpg", [])
    end

    test "malformed and out-of-range explicit HTTP ports are rejected" do
      for source <- [
            "https://example.com:abc/cat.jpg",
            "https://example.com:/cat.jpg",
            "https://example.com:+443/cat.jpg",
            "https://example.com:0/cat.jpg",
            "https://example.com:65536/cat.jpg",
            "http://[::1]:abc/cat.jpg"
          ] do
        assert {:error, {:invalid_source, _reason}} = Source.translate(source, []), source
      end
    end

    test "malformed inner URL percent escapes are rejected" do
      assert {:error, {:invalid_source, _reason}} =
               Source.translate("https://example.com/cat%zz.jpg", [])

      assert {:error, {:invalid_source, _reason}} =
               Source.translate("https://example.com/cat.jpg?token=%zz", [])
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
