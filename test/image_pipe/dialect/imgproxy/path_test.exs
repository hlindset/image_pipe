defmodule ImagePipe.Dialect.Imgproxy.PathTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy.Path

  test "extracts signature, signed path, and repaired path info" do
    conn = conn(:get, "/_/rs%3Afit%3A300/plain/local:/images/cat.jpg")

    assert {:ok, "_", "/rs:fit:300/plain/local:///images/cat.jpg", path_info} =
             Path.extract(conn)

    assert path_info == ["rs:fit:300", "plain", "local:", "", "", "images", "cat.jpg"]
  end

  test "extracts path under plug script name" do
    conn =
      conn(:get, "/img/_/plain/images/cat.jpg")
      |> Map.put(:script_name, ["img"])

    assert {:ok, "_", "/plain/images/cat.jpg", ["plain", "images", "cat.jpg"]} =
             Path.extract(conn)
  end

  test "splits option segments from plain source marker" do
    assert Path.split_source(["w:100", "plain", "images", "cat.jpg"]) ==
             {:ok, ["w:100"], :plain, ["images", "cat.jpg"]}
  end

  test "keeps raw encoded at-signs in source before parsing extension suffix" do
    assert Path.parse_plain_source(["images", "cat%40v1.jpg@webp"]) ==
             {:ok, "images/cat%40v1.jpg", :webp}
  end

  test "rejects malformed percent encoding without raising" do
    assert Path.parse_plain_source(["images", "cat%ZZ.jpg"]) ==
             {:error, {:invalid_percent_encoding, "cat%ZZ.jpg"}}
  end

  describe "extract errors" do
    test "rejects empty and signature-only paths" do
      assert Path.extract(conn(:get, "/")) == {:error, :missing_signature}
      assert Path.extract(conn(:get, "/_")) == {:error, :missing_signed_path}
    end

    test "rejects paths that start with an empty signature" do
      conn =
        conn(:get, "/")
        |> Map.put(:request_path, "//plain/images/cat.jpg")
        |> Map.put(:path_info, ["", "plain", "images", "cat.jpg"])

      assert Path.extract(conn) == {:error, :missing_signature}
    end

    test "strips multi-segment script_name prefixes before extracting" do
      conn =
        conn(:get, "/proxy/v1/_/plain/images/cat.jpg")
        |> Map.put(:script_name, ["proxy", "v1"])

      assert {:ok, "_", "/plain/images/cat.jpg", ["plain", "images", "cat.jpg"]} =
               Path.extract(conn)
    end

    test "treats a path equal to script_name as the mounted root" do
      conn =
        conn(:get, "/img")
        |> Map.put(:script_name, ["img"])
        |> Map.put(:request_path, "/img")

      assert Path.extract(conn) == {:error, :missing_signature}
    end
  end

  describe "path repair" do
    test "repairs lowercase percent-encoded option colons" do
      conn = conn(:get, "/_/w%3a300/plain/images/cat.jpg")

      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path == "/w:300/plain/images/cat.jpg"
    end

    test "repairs http plain URL scheme normalization" do
      conn = conn(:get, "/_/plain/http:/example.com/image.jpg")

      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path == "/plain/http://example.com/image.jpg"
    end
  end

  describe "split_source" do
    test "rejects paths with only option-shaped segments and no source" do
      assert Path.split_source(["w:100", "h:200"]) == {:error, :missing_source_kind}
    end

    test "rejects paths where plain has no source segments" do
      assert Path.split_source(["w:100", "plain"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "splits empty options when plain is first" do
      assert Path.split_source(["plain", "images", "cat.jpg"]) ==
               {:ok, [], :plain, ["images", "cat.jpg"]}
    end

    test "stops at the first plain marker" do
      assert Path.split_source(["plain", "plain", "cat.jpg"]) ==
               {:ok, [], :plain, ["plain", "cat.jpg"]}
    end
  end

  describe "split_source with encoded sources" do
    test "splits option segments from encoded source segments" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.split_source(["w:100", "h:200", encoded]) ==
               {:ok, ["w:100", "h:200"], :encoded, [encoded]}
    end

    test "splits chunked encoded source segments" do
      encoded = encoded_source("http://example.com/images/cat.jpg")
      [first, second] = chunked(encoded, 12)

      assert Path.split_source(["rs:fit:300:400", first, second]) ==
               {:ok, ["rs:fit:300:400"], :encoded, [first, second]}
    end

    test "uses the first plain marker before encoded-source detection" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.split_source(["w:100", "plain", encoded]) ==
               {:ok, ["w:100"], :plain, [encoded]}
    end

    test "later plain segments remain encoded source chunks" do
      encoded = encoded_source("images/cat.jpg")
      [first, second] = chunked(encoded, 8)

      assert Path.split_source(["w:100", first, "plain", second]) ==
               {:ok, ["w:100"], :encoded, [first, "plain", second]}
    end

    test "treats bare option aliases as encoded source chunks" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.split_source(["ar", "fl", "padding", "pd", encoded]) ==
               {:ok, [], :encoded, ["ar", "fl", "padding", "pd", encoded]}
    end

    test "treats pipeline separators as encoded source chunks" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.split_source(["w:100", "-", "h:200", encoded]) ==
               {:ok, ["w:100"], :encoded, ["-", "h:200", encoded]}
    end

    test "treats other bare option aliases as encoded source chunks" do
      assert Path.split_source(["w", "abc"]) ==
               {:ok, [], :encoded, ["w", "abc"]}
    end

    test "treats bare preset names as encoded source chunks" do
      assert Path.split_source(["preset", encoded_source("images/cat.jpg")]) ==
               {:ok, [], :encoded, ["preset", encoded_source("images/cat.jpg")]}

      assert Path.split_source(["pr", encoded_source("images/cat.jpg")]) ==
               {:ok, [], :encoded, ["pr", encoded_source("images/cat.jpg")]}
    end

    test "keeps colon-bearing options before encoded sources" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.split_source(["ar:true", "fl:true:false", "pd:10", encoded]) ==
               {:ok, ["ar:true", "fl:true:false", "pd:10"], :encoded, [encoded]}
    end

    test "recognizes encrypted source marker only when first raw source segment is exactly enc" do
      assert Path.split_source(["enc", "payload"]) == {:ok, [], :encrypted, ["payload"]}

      assert Path.split_source(["encA"]) == {:ok, [], :encoded, ["encA"]}
    end

    test "preserves existing missing source errors" do
      assert Path.split_source(["w:100", "h:200"]) == {:error, :missing_source_kind}

      assert Path.split_source(["w:100", "plain"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end
  end

  describe "parse_plain_source" do
    test "parses known output extension suffixes" do
      assert Path.parse_plain_source(["images", "cat.jpg@avif"]) ==
               {:ok, "images/cat.jpg", :avif}

      assert Path.parse_plain_source(["images", "cat.jpg@jpg"]) ==
               {:ok, "images/cat.jpg", :jpeg}
    end

    test "allows a trailing output extension separator without an extension" do
      assert Path.parse_plain_source(["images", "cat.jpg@"]) ==
               {:ok, "images/cat.jpg", nil}
    end

    test "rejects unknown output extension suffixes" do
      assert Path.parse_plain_source(["images", "cat.jpg@gif"]) ==
               {:error,
                {:invalid_format, "gif", ["jxl", "webp", "avif", "jpeg", "jpg", "png", "best"]}}
    end

    test "rejects empty source identifiers" do
      assert Path.parse_plain_source([""]) ==
               {:error, {:missing_source_identifier, "plain"}}

      assert Path.parse_plain_source(["@webp"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "rejects repeated output extension separators" do
      assert Path.parse_plain_source(["cat.jpg@webp@png"]) ==
               {:error, {:multiple_output_extension_separators, "cat.jpg@webp@png"}}
    end

    test "leaves percent-encoded source path segments raw for source translation" do
      assert Path.parse_plain_source(["images", "cat%20dog.jpg"]) ==
               {:ok, "images/cat%20dog.jpg", nil}
    end
  end

  describe "parse_source with encoded sources" do
    test "decodes unpadded URL-safe Base64 source" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded]) ==
               {:ok, "images/cat.jpg", nil}
    end

    test "decodes padded URL-safe Base64 source by trimming trailing padding" do
      encoded = encoded_source("images/cat.jpg", padding: true)

      assert Path.parse_source(:encoded, [encoded]) ==
               {:ok, "images/cat.jpg", nil}
    end

    test "joins encoded chunks without slashes" do
      encoded = encoded_source("http://example.com/images/cat.jpg")
      [first, second] = chunked(encoded, 12)

      assert Path.parse_source(:encoded, [first, second]) ==
               {:ok, "http://example.com/images/cat.jpg", nil}
    end

    test "parses encoded output extension suffixes" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded <> ".webp"]) ==
               {:ok, "images/cat.jpg", :webp}

      assert Path.parse_source(:encoded, [encoded <> ".avif"]) ==
               {:ok, "images/cat.jpg", :avif}

      assert Path.parse_source(:encoded, [encoded <> ".jpg"]) ==
               {:ok, "images/cat.jpg", :jpeg}

      assert Path.parse_source(:encoded, [encoded <> ".jpeg"]) ==
               {:ok, "images/cat.jpg", :jpeg}

      assert Path.parse_source(:encoded, [encoded <> ".png"]) ==
               {:ok, "images/cat.jpg", :png}

      assert Path.parse_source(:encoded, [encoded <> ".best"]) ==
               {:ok, "images/cat.jpg", :best}
    end

    test "allows a trailing encoded output separator without an extension" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded <> "."]) ==
               {:ok, "images/cat.jpg", nil}
    end

    test "rejects empty encoded source identifiers" do
      assert Path.parse_source(:encoded, [""]) ==
               {:error, {:missing_source_identifier, "encoded"}}

      assert Path.parse_source(:encoded, [".webp"]) ==
               {:error, {:missing_source_identifier, "encoded"}}
    end

    test "rejects invalid encoded source alphabet and length" do
      assert Path.parse_source(:encoded, ["not+base64"]) ==
               {:error, {:invalid_encoded_source, :base64}}

      assert Path.parse_source(:encoded, ["abcde"]) ==
               {:error, {:invalid_encoded_source, :base64}}
    end

    test "treats slash only as an encoded chunk separator" do
      assert Path.parse_source(:encoded, ["a", "+", "b"]) ==
               {:error, {:invalid_encoded_source, :base64}}
    end

    test "rejects decoded bytes that are not UTF-8" do
      encoded = Base.url_encode64(<<255>>, padding: false)

      assert Path.parse_source(:encoded, [encoded]) ==
               {:error, {:invalid_encoded_source, :utf8}}
    end

    test "rejects repeated encoded output extension separators" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded <> ".webp.png"]) ==
               {:error, {:multiple_output_extension_separators, encoded <> ".webp.png"}}
    end

    test "rejects unknown encoded output format suffixes" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded <> ".gif"]) ==
               {:error,
                {:invalid_format, "gif", ["jxl", "webp", "avif", "jpeg", "jpg", "png", "best"]}}
    end

    test "discards SEO filename before joining chunks and parsing output suffix" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded <> ".webp", "puppy.jpg"],
               base64_url_includes_filename: true
             ) ==
               {:ok, "images/cat.jpg", :webp}
    end

    test "keeps current encoded source behavior when SEO filename mode is disabled" do
      encoded = encoded_source("images/cat.jpg")

      assert Path.parse_source(:encoded, [encoded, "puppy.jpg"],
               base64_url_includes_filename: false
             ) ==
               {:error, {:invalid_encoded_source, :utf8}}
    end
  end

  defp encoded_source(source, opts \\ []) do
    padding = Keyword.get(opts, :padding, false)
    Base.url_encode64(source, padding: padding)
  end

  defp chunked(value, first_size) do
    first = binary_part(value, 0, first_size)
    second = binary_part(value, first_size, byte_size(value) - first_size)
    [first, second]
  end
end
