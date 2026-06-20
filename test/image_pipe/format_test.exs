defmodule ImagePipe.FormatTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Format

  test "defines canonical source and output format families" do
    assert Format.output_formats() == [:avif, :webp, :jpeg, :png]
    assert Format.source_only_formats() == [:heif, :tiff, :jpeg2000, :jpeg_xl]

    assert Format.source_formats() == [
             :avif,
             :webp,
             :jpeg,
             :png,
             :heif,
             :tiff,
             :jpeg2000,
             :jpeg_xl
           ]
  end

  test "classifies format families" do
    assert Format.output_format?(:avif)
    assert Format.output_format?(:png)
    refute Format.output_format?(:heif)

    assert Format.source_only_format?(:heif)
    assert Format.source_only_format?(:jpeg_xl)
    refute Format.source_only_format?(:jpeg)

    assert Format.source_format?(:jpeg2000)
    refute Format.source_format?(:svg)
  end

  test "output MIME mapping covers the canonical output formats" do
    assert Format.output_mime_types() |> Keyword.keys() == Format.output_formats()

    assert Format.output_mime_type_values() == [
             "image/avif",
             "image/webp",
             "image/jpeg",
             "image/png"
           ]
  end

  test "maps MIME types to format atoms" do
    assert Format.format_from_mime_type("image/avif") == {:ok, :avif}
    assert Format.format_from_mime_type("image/webp") == {:ok, :webp}
    assert Format.format_from_mime_type("image/jpeg") == {:ok, :jpeg}
    assert Format.format_from_mime_type("image/jpg") == {:ok, :jpeg}
    assert Format.format_from_mime_type("image/png") == {:ok, :png}
    assert Format.format_from_mime_type(" image/WEBP; charset=utf-8") == {:ok, :webp}
    assert Format.format_from_mime_type("IMAGE/PNG; charset=binary") == {:ok, :png}

    assert Format.format_from_mime_type("image/gif") ==
             {:error, {:unsupported_output_format, "image/gif"}}
  end

  test "maps format atoms to MIME types" do
    assert Format.mime_type(:avif) == {:ok, "image/avif"}
    assert Format.mime_type(:webp) == {:ok, "image/webp"}
    assert Format.mime_type(:jpeg) == {:ok, "image/jpeg"}
    assert Format.mime_type(:png) == {:ok, "image/png"}
    assert Format.mime_type(:gif) == :error
  end

  test "supports_color_profile?/1 mirrors imgproxy SupportsColourProfile" do
    assert Format.supports_color_profile?(:jpeg) == true
    assert Format.supports_color_profile?(:png) == true
    assert Format.supports_color_profile?(:webp) == true
    assert Format.supports_color_profile?(:avif) == true
  end

  describe "supports_hdr?/1" do
    test "AVIF and PNG carry HDR; WebP and JPEG do not" do
      assert Format.supports_hdr?(:avif)
      assert Format.supports_hdr?(:png)
      refute Format.supports_hdr?(:webp)
      refute Format.supports_hdr?(:jpeg)
    end
  end

  describe "supports_alpha?/1" do
    test "AVIF, WebP, and PNG carry alpha; JPEG does not" do
      assert Format.supports_alpha?(:avif)
      assert Format.supports_alpha?(:webp)
      assert Format.supports_alpha?(:png)
      refute Format.supports_alpha?(:jpeg)
    end
  end

  describe "supports_quality?/1" do
    test "is true for lossy-quality formats, false for png" do
      assert Format.supports_quality?(:jpeg)
      assert Format.supports_quality?(:webp)
      assert Format.supports_quality?(:avif)
      refute Format.supports_quality?(:png)
    end
  end

  test "maps MIME types to encoder suffixes" do
    assert Format.suffix!("image/avif") == ".avif"
    assert Format.suffix!("image/webp") == ".webp"
    assert Format.suffix!("image/jpeg") == ".jpg"
    assert Format.suffix!("image/png") == ".png"

    assert Format.suffix("image/jpeg") == {:ok, ".jpg"}

    assert Format.suffix("image/gif") ==
             {:error, {:unsupported_output_format, "image/gif"}}
  end
end
