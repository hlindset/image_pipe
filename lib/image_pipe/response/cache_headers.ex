defmodule ImagePipe.Response.CacheHeaders do
  @moduledoc false

  alias ImagePipe.Representation

  @enforce_keys [:representation_headers, :headers, :etag]
  defstruct @enforce_keys

  @plug_default_cache_control "max-age=0, private, must-revalidate"

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          representation_headers: [header()],
          headers: [header()],
          etag: String.t() | nil
        }

  @doc false
  @spec from_representation(ImagePipe.Representation.t()) :: t()
  def from_representation(%ImagePipe.Representation{} = representation) do
    %__MODULE__{
      etag: representation.etag,
      representation_headers: vary_headers(representation.vary),
      headers: Representation.response_headers(representation)
    }
  end

  @doc false
  @spec host_cache_control?([String.t()]) :: boolean()
  def host_cache_control?([]), do: false
  def host_cache_control?([@plug_default_cache_control]), do: false
  def host_cache_control?(_headers), do: true

  defp vary_headers([]), do: []
  defp vary_headers(names), do: [{"vary", Enum.join(names, ", ")}]
end
