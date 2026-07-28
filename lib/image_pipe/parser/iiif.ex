defmodule ImagePipe.Parser.IIIF do
  @moduledoc "IIIF Image API 3.0 (Level 2) parser. Positional grammar -> ImagePipe.Plan."

  @behaviour ImagePipe.Parser

  # Top-level rather than a sub-boundary of `ImagePipe.Parser`: the grammar,
  # plan building, and identifier resolution live in `ImagePipe.Dialect.IIIF`,
  # and a sub-boundary may only depend on a sibling, its parent, or a parent's
  # dep — naming the dialect from here requires being its sibling. Removed with
  # the file in Task 11.
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Dialect.IIIF,
      ImagePipe.Parser,
      ImagePipe.Plan
    ],
    exports: []

  import Plug.Conn, only: [send_resp: 3]

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Plan.Output.QualitySearch

  @dialect_schema NimbleOptions.new!(
                    resolver: [
                      type: {:custom, IIIF.Resolver, :validate, []},
                      required: true
                    ],
                    formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
                    qualities: [
                      type: {:list, :atom},
                      default: [:default, :color, :gray, :bitonal]
                    ],
                    tile_size: [type: :pos_integer, default: 512],
                    max_width: [type: :pos_integer],
                    max_height: [type: :pos_integer],
                    max_area: [type: :pos_integer]
                  )

  @dialect_keys [:resolver, :formats, :qualities, :tile_size, :max_width, :max_height, :max_area]

  # The full neutral surface is honored; the reject seam is a no-op today.
  @supported_neutral :all

  @impl true
  def validate_options!(opts) do
    iiif = Keyword.get(opts, :iiif, [])

    unless Keyword.keyword?(iiif) do
      raise ArgumentError, "iiif: expected a keyword list"
    end

    {neutral, rest} = Keyword.split(iiif, ImagePipe.Config.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    unless unknown == [] do
      raise ArgumentError, "iiif: unknown keys #{inspect(Keyword.keys(unknown))}"
    end

    dialect = NimbleOptions.validate!(dialect, @dialect_schema)
    validate_max_bounds!(dialect)

    neutral =
      neutral
      |> ImagePipe.Config.reject_unsupported!(@supported_neutral, "IIIF")
      |> ImagePipe.Config.resolve!(iiif_overlay())

    # Config-only dialect: the autoquality search is fully determined here, so
    # surface a bad method/target combination at boot rather than per request.
    case QualitySearch.from_config(neutral) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "iiif: invalid autoquality config: #{inspect(reason)}"
    end

    Keyword.put(opts, :iiif, Keyword.merge(neutral, dialect))
  end

  defp iiif_overlay, do: []

  # IIIF Image API 3.0 §5.1: maxWidth must be specified if maxHeight is specified.
  defp validate_max_bounds!(iiif) do
    if Keyword.has_key?(iiif, :max_height) and not Keyword.has_key?(iiif, :max_width) do
      raise ArgumentError, "iiif: max_height requires max_width (IIIF Image API 3.0 §5.1)"
    end

    :ok
  end

  @impl true
  def parse(%Plug.Conn{} = conn, opts), do: IIIF.parse_plan(conn, Keyword.fetch!(opts, :iiif))

  # The Plug delegates with the WRAPPED parse error `{:error, reason}`. Unwrap before
  # mapping to a status, or 404 is unreachable and every error becomes 400.
  @impl true
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    {status, body} = status_for(reason)
    send_resp(conn, status, body)
  end

  defp status_for(:not_found), do: {404, "not found"}

  defp status_for({tag, _raw})
       when tag in [
              :invalid_region,
              :invalid_size,
              :invalid_rotation,
              :invalid_quality,
              :invalid_format
            ],
       do: {400, "bad request"}

  defp status_for(_), do: {400, "bad request"}
end
