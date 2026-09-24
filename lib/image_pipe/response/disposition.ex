defmodule ImagePipe.Response.Disposition do
  @moduledoc false

  alias ImagePipe.Plan.Request

  @extensions %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp",
    "image/avif" => "avif",
    "application/json" => "json",
    "text/plain" => "txt"
  }

  def render(%Request{} = request, content_type) do
    case Map.fetch(@extensions, content_type) do
      {:ok, extension} -> {:ok, disposition(request, extension)}
      :error -> {:error, {:unsupported_delivery_content_type, content_type}}
    end
  end

  defp disposition(%Request{filename: nil, attachment?: attachment?}, _extension),
    do: mode(attachment?)

  defp disposition(%Request{filename: stem, attachment?: attachment?}, extension),
    do: ~s(#{mode(attachment?)}; filename="#{stem}.#{extension}")

  defp mode(true), do: "attachment"
  defp mode(false), do: "inline"
end
