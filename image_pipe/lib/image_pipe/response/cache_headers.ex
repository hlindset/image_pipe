defmodule ImagePipe.Response.CacheHeaders do
  @moduledoc false

  import Plug.Conn, only: [get_resp_header: 2]

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

  @doc false
  # Folds `added_names` into whatever `Vary` the conn already carries, returning
  # the single header value to emit. Every writer of `Vary` on a response goes
  # through here: a delivery stage that varies for its own reason (a render
  # terminal negotiating an offered content type) must not drop the names a
  # previous stage established. `Vary: *` already covers everything, so it
  # absorbs the addition instead of growing a list.
  @spec merge_vary(Plug.Conn.t(), [String.t()]) :: String.t()
  def merge_vary(%Plug.Conn{} = conn, added_names) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&split_vary/1)

    if Enum.any?(existing, &(String.downcase(&1) == "*")) do
      "*"
    else
      existing
      |> Kernel.++(added_names)
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.join(", ")
    end
  end

  @doc false
  @spec split_vary(String.t()) :: [String.t()]
  def split_vary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp vary_headers([]), do: []
  defp vary_headers(names), do: [{"vary", Enum.join(names, ", ")}]
end
