defmodule ImagePipe.Response.Disposition do
  @moduledoc false

  alias ImagePipe.Plan.Spec

  @extensions %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp",
    "image/avif" => "avif",
    "image/gif" => "gif",
    "image/tiff" => "tiff",
    "image/heif" => "heif",
    "image/jxl" => "jxl",
    "image/jp2" => "jp2",
    "application/json" => "json",
    "text/plain" => "txt"
  }

  def render(%Spec{} = request, content_type) do
    case Map.fetch(@extensions, content_type) do
      {:ok, extension} -> {:ok, disposition(request, extension)}
      :error -> {:error, {:unsupported_delivery_content_type, content_type}}
    end
  end

  defp disposition(%Spec{filename: nil, attachment?: attachment?}, _extension),
    do: mode(attachment?)

  defp disposition(%Spec{filename: stem, attachment?: attachment?}, extension),
    do: ~s(#{mode(attachment?)}; filename="#{stem}.#{extension}")

  defp mode(true), do: "attachment"
  defp mode(false), do: "inline"
end
