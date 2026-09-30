defmodule ImagePipe.Format.DetectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Format.Detector

  describe "detect/1 magic bytes" do
    test "PNG signature" do
      assert Detector.detect(<<0x89, "PNG\r\n\x1a\n", "rest...">>) == :png
    end

    test "JPEG SOI" do
      assert Detector.detect(<<0xFF, 0xD8, 0xFF, 0xE0>>) == :jpeg
    end

    test "GIF87a and GIF89a" do
      assert Detector.detect(<<"GIF87a", 1, 0, 1, 0>>) == :gif
      assert Detector.detect(<<"GIF89a", 1, 0, 1, 0>>) == :gif
    end

    test "BMP" do
      assert Detector.detect(<<"BM", 0, 0, 0, 0>>) == :bmp
    end

    test "ICO" do
      assert Detector.detect(<<0x00, 0x00, 0x01, 0x00, 1, 0>>) == :ico
    end

    test "WebP RIFF/WEBP with arbitrary size bytes" do
      assert Detector.detect(<<"RIFF", 0xAA, 0xBB, 0xCC, 0xDD, "WEBP", "VP8 ">>) == :webp
    end

    test "JXL codestream and container" do
      assert Detector.detect(<<0xFF, 0x0A, 0, 0>>) == :jpeg_xl

      assert Detector.detect(<<0x00, 0x00, 0x00, 0x0C, "JXL ", 0x0D, 0x0A, 0x87, 0x0A>>) ==
               :jpeg_xl
    end

    test "JPEG 2000 signature box and J2K codestream" do
      assert Detector.detect(<<0x00, 0x00, 0x00, 0x0C, "jP  ", 0x0D, 0x0A, 0x87, 0x0A>>) ==
               :jpeg2000

      assert Detector.detect(<<0xFF, 0x4F, 0xFF, 0x51, 0, 0>>) == :jpeg2000
    end

    test "AVIF ftyp brand with arbitrary box size" do
      assert Detector.detect(<<0, 0, 0, 0x20, "ftypavif", "more">>) == :avif
    end

    test "every HEIC ftyp brand" do
      for brand <- ["heic", "heix", "hevc", "heim", "heis", "hevm", "hevs", "mif1"] do
        assert Detector.detect(<<0, 0, 0, 0x20, "ftyp", brand::binary, "more">>) == :heif
      end
    end

    test "TIFF little-endian and big-endian" do
      assert Detector.detect(<<"II", 0x2A, 0x00, 0, 0>>) == :tiff
      assert Detector.detect(<<"MM", 0x00, 0x2A, 0, 0>>) == :tiff
    end

    test "unrecognized and truncated inputs are :unknown" do
      assert Detector.detect(<<"not an image at all">>) == :unknown
      assert Detector.detect(<<0xFF>>) == :unknown
      assert Detector.detect(<<>>) == :unknown
    end

    test "a truncated ftyp box with no brand is :unknown (matcher is total over short input)" do
      assert Detector.detect(<<0, 0, 0, 0x20, "ftyp">>) == :unknown
    end
  end

  describe "detect/1 SVG structural scan" do
    test "bare svg root" do
      assert Detector.detect(~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)) == :svg
    end

    test "leading whitespace" do
      assert Detector.detect("\n\t  <svg></svg>") == :svg
    end

    test "UTF-8 BOM" do
      assert Detector.detect(<<0xEF, 0xBB, 0xBF, "<svg></svg>">>) == :svg
    end

    test "XML declaration before root" do
      assert Detector.detect(~s(<?xml version="1.0" encoding="UTF-8"?>\n<svg/>)) == :svg
    end

    test "comment before root" do
      assert Detector.detect("<!-- a comment with > inside -->\n<svg/>") == :svg
    end

    test "DOCTYPE with internal subset containing >" do
      doctype = ~s(<!DOCTYPE svg [ <!ENTITY x "a > b"> ]>)
      assert Detector.detect(doctype <> "<svg/>") == :svg
    end

    test "namespace-prefixed root" do
      assert Detector.detect(~s(<svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>)) == :svg
    end

    test "self-closing root" do
      assert Detector.detect("<svg/>") == :svg
    end

    test "non-svg XML is :unknown" do
      assert Detector.detect(~s(<?xml version="1.0"?><html><body/></html>)) == :unknown
      assert Detector.detect("<rss><channel/></rss>") == :unknown
    end

    test "an element whose name merely starts with svg is not svg" do
      assert Detector.detect("<svgfoo></svgfoo>") == :unknown
    end

    test "plain text is :unknown" do
      assert Detector.detect("hello world, not markup") == :unknown
    end
  end

  describe "detect/1 properties" do
    @confident_prefixes %{
      png: <<0x89, "PNG\r\n\x1a\n">>,
      jpeg: <<0xFF, 0xD8, 0xFF>>,
      gif: <<"GIF89a">>,
      webp: <<"RIFF", 0, 0, 0, 0, "WEBP">>,
      avif: <<0, 0, 0, 0x20, "ftypavif">>,
      jpeg2000: <<0, 0, 0, 0x0C, "jP  ", 0x0D, 0x0A, 0x87, 0x0A>>,
      tiff: <<"II", 0x2A, 0x00>>
    }

    property "a confident prefix is stable under arbitrary appended bytes" do
      prefixes = Map.to_list(@confident_prefixes)

      check all {format, prefix} <- member_of(prefixes),
                suffix <- binary() do
        assert Detector.detect(prefix <> suffix) == format
      end
    end

    property "detection over a 32KB peek equals detection over the full input" do
      prefixes = Map.values(@confident_prefixes)

      check all prefix <- member_of(prefixes),
                tail <- binary(min_length: 0, max_length: 64 * 1024) do
        full = prefix <> tail
        peek = binary_part(full, 0, min(byte_size(full), 32 * 1024))
        assert Detector.detect(peek) == Detector.detect(full)
      end
    end
  end
end
