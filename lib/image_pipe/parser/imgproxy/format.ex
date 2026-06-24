defmodule ImagePipe.Parser.Imgproxy.Format do
  @moduledoc false

  @source_format_names ~w(jxl webp avif jpeg jpg png best)

  @source_formats %{
    "jxl" => :jpeg_xl,
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "jpg" => :jpeg,
    "png" => :png,
    "best" => :best
  }

  def parse(value) do
    case Map.fetch(@source_formats, value) do
      {:ok, parsed_value} -> {:ok, parsed_value}
      :error -> {:error, {:invalid_format, value, @source_format_names}}
    end
  end
end
