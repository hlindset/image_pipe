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
end
