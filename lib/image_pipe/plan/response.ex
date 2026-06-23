defmodule ImagePipe.Plan.Response do
  @moduledoc """
  Delivery metadata attached to an `ImagePipe.Plan`.

  Parsers use this struct for response-specific request options such as
  `Content-Disposition` and delivery filename selection.
  """

  @delivery_content_types ["image/jxl", "image/jpeg", "image/png", "image/webp", "image/avif"]

  defstruct disposition: :default, filename: nil

  @type t :: %__MODULE__{
          disposition: :default | :inline | :attachment,
          filename: String.t() | nil
        }

  @doc """
  Returns true when a filename stem is safe for response delivery.
  """
  @spec valid_filename?(term()) :: boolean()
  def valid_filename?(stem) when is_binary(stem) do
    String.valid?(stem) and stem != "" and not String.contains?(stem, ["/", "\\"]) and
      not has_control_character?(stem)
  end

  def valid_filename?(_stem), do: false

  @doc false
  @spec content_disposition(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def content_disposition(%__MODULE__{} = response, content_type) when is_binary(content_type) do
    with {:ok, extension} <- delivery_extension(content_type) do
      {:ok, render_disposition(response, extension)}
    end
  end

  defp delivery_extension(content_type) do
    if content_type in @delivery_content_types do
      content_type
      |> MIME.extensions()
      |> delivery_extension(content_type)
    else
      {:error, {:unsupported_delivery_content_type, content_type}}
    end
  end

  defp delivery_extension([extension | _rest], _content_type), do: {:ok, extension}

  defp delivery_extension([], content_type),
    do: {:error, {:unsupported_delivery_content_type, content_type}}

  defp render_disposition(%__MODULE__{filename: nil} = response, _extension) do
    disposition(response.disposition)
  end

  defp render_disposition(%__MODULE__{filename: stem} = response, extension)
       when is_binary(stem) do
    filename = stem <> "." <> extension
    encoded_filename = URI.encode(filename, &URI.char_unreserved?/1)

    disposition =
      ~s(#{disposition(response.disposition)}; filename="#{encoded_filename}")

    if encoded_filename == filename do
      disposition
    else
      disposition <> "; filename*=utf-8''#{encoded_filename}"
    end
  end

  defp disposition(:attachment), do: "attachment"
  defp disposition(:inline), do: "inline"
  defp disposition(:default), do: "inline"

  defp has_control_character?(stem) do
    stem
    |> String.to_charlist()
    |> Enum.any?(&(&1 in 0..31 or &1 == 127))
  end
end
