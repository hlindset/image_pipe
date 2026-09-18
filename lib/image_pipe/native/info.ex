defmodule ImagePipe.Native.Info do
  @moduledoc false

  alias ImagePipe.Decode
  alias ImagePipe.Format
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Source
  alias ImagePipe.Transform.SourceGeometry
  alias Vix.Vips.Image, as: VipsImage

  @identity {__MODULE__, 1}

  @spec identity() :: {module(), pos_integer()}
  def identity, do: @identity

  @spec render_source(Source.Resolved.t(), Request.t(), keyword()) ::
          {:ok, String.t(), iodata()} | {:error, term()}
  def render_source(%Source.Resolved{} = resolved, %Request{} = request, config) do
    Decode.with_image(
      resolved,
      request,
      config,
      fn state, geometry ->
        {content_type, body} = render(source_info(state.image, geometry))
        {:ok, content_type, body}
      end
    )
  end

  @spec render(SourceInfo.t()) :: {String.t(), iodata()}
  def render(%SourceInfo{} = info) do
    {width, height} = SourceInfo.display_dimensions(info)

    body =
      %{
        "format" => Atom.to_string(info.format),
        "mime_type" => Format.mime_type!(info.format),
        "width" => width,
        "height" => height,
        "orientation" => info.orientation
      }
      |> maybe_put("size", info.byte_size)
      |> JSON.encode_to_iodata!()

    {"application/json", body}
  end

  defp source_info(image, %SourceGeometry{
         storage_dimensions: {width, height},
         source_format: format,
         debug_facts: debug_facts
       }) do
    %SourceInfo{
      format: format,
      width: width,
      height: height,
      orientation: exif_orientation(image),
      byte_size: Map.get(debug_facts, :source_bytes)
    }
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _absent_or_invalid -> 1
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
