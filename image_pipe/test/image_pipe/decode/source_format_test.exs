defmodule ImagePipe.Decode.SourceFormatTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Decode.SourceFormat

  test "UltraHDR JPEGs belong to the JPEG family" do
    assert SourceFormat.classify_loader("uhdrload_buffer", fn _ -> :error end) == {:ok, :jpeg}
  end

  test "loaders outside the accepted families are unsupported" do
    for loader <- ["dcrawload", "magickload_buffer", "pdfload_buffer", "ppmload_buffer"] do
      assert SourceFormat.classify_loader(loader, fn _ -> :error end) ==
               {:error, {:unsupported_source_format, :unknown}}
    end
  end

  # libvips sniffs, so a loader of another family can claim a source's bytes.
  test "an image from a loader outside the detected family is rejected" do
    png = Image.new!(8, 6) |> Image.write!(:memory, suffix: ".png") |> Image.open!()

    assert SourceFormat.verify(png, :jpeg) ==
             {:error, {:unsupported_source_format, :jpeg, "pngload_buffer"}}

    assert SourceFormat.verify(png, :png) == {:ok, :png}
  end
end
