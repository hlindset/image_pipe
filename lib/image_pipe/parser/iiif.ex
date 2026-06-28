defmodule ImagePipe.Parser.IIIF do
  @moduledoc "IIIF Image API 3.0 (Level 2) parser. Positional grammar -> ImagePipe.Plan."

  @behaviour ImagePipe.Parser

  use Boundary,
    deps: [
      ImagePipe.Format,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Renderer
    ],
    exports: []

  import Plug.Conn, only: [send_resp: 3]

  alias ImagePipe.Parser.IIIF.Grammar
  alias ImagePipe.Parser.IIIF.Path
  alias ImagePipe.Parser.IIIF.PlanBuilder

  @dialect_schema NimbleOptions.new!(
                    resolver: [type: {:custom, __MODULE__, :validate_resolver, []}, required: true],
                    formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
                    qualities: [type: {:list, :atom}, default: [:default, :color, :gray, :bitonal]],
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
    case ImagePipe.Plan.Output.QualitySearch.from_config(neutral) do
      {:ok, _} -> :ok
      {:error, reason} -> raise ArgumentError, "iiif: invalid autoquality config: #{inspect(reason)}"
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

  @doc false
  def validate_resolver({mod, ropts} = r) when is_atom(mod) and is_list(ropts) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :resolve, 2),
      do: {:ok, r},
      else: {:error, "resolver module must export resolve/2"}
  end

  def validate_resolver(_), do: {:error, "resolver must be {Module, opts}"}

  @impl true
  def parse(%Plug.Conn{} = conn, opts) do
    iiif = Keyword.fetch!(opts, :iiif)

    case Path.classify(conn) do
      {:redirect, _id, location} ->
        {:redirect, 303, location}

      {:info, id} ->
        with {:ok, source} <- resolve(id, iiif) do
          PlanBuilder.info_plan(source, Path.base_uri(conn) <> "/" <> URI.encode(id), iiif)
        end

      {:image, id, tokens} ->
        with {:ok, source} <- resolve(id, iiif),
             {:ok, parsed} <- parse_tokens(tokens) do
          PlanBuilder.image_plan(
            source,
            parsed,
            Keyword.put(iiif, :debug?, debug_requested?(conn))
          )
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  # The Plug delegates with the WRAPPED parse error `{:error, reason}`. Unwrap before
  # mapping to a status, or 404 is unreachable and every error becomes 400.
  @impl true
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    {status, body} = status_for(reason)
    send_resp(conn, status, body)
  end

  # `?debug=1` (also `?debug=true`) opts the response into `X-ImagePipe-*` debug
  # headers, honored only under the `allow_debug_headers: true` mount flag. The
  # IIIF Image API path grammar has no free slot, so the trigger is an
  # out-of-band query param — an ImagePipe extension, not part of the IIIF spec.
  # It is read leniently: any non-true value (absent, `0`, `false`, garbage)
  # disables it, so a malformed flag never fails an otherwise-valid image
  # request. IIIF has no request signing, so the trigger is unprotected; see
  # docs/iiif_3_support_matrix.md.
  defp debug_requested?(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    Map.get(conn.query_params, "debug") in ["1", "true"]
  end

  defp resolve(id, iiif) do
    {mod, ropts} = Keyword.fetch!(iiif, :resolver)

    case mod.resolve(id, ropts) do
      {:ok, %_{} = source} -> {:ok, source}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_tokens(%{region: r, size: s, rotation: rot, quality: q, format: f}) do
    with {:ok, region} <- Grammar.region(r),
         {:ok, size} <- Grammar.size(s),
         {:ok, rotation} <- Grammar.rotation(rot),
         {:ok, quality} <- Grammar.quality(q),
         {:ok, format} <- Grammar.format(f) do
      {:ok, %{region: region, size: size, rotation: rotation, quality: quality, format: format}}
    end
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
