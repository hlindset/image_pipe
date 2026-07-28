defmodule ImagePipe.Dialect.IIIF do
  @moduledoc """
  IIIF Image API 3.0 (Level 2) dialect — the declarative tier's reference
  implementation. Mount it with:

      plug ImagePipe.Plug,
        dialect: ImagePipe.Dialect.IIIF,
        resolver: {MyApp.Resolver, []},
        sources: [...],
        max_width: 4000

  The positional grammar (`{id}/{region}/{size}/{rotation}/{quality}.{format}`)
  lowers to a product-neutral `%ImagePipe.Plan{}`; `ImagePipe.Dialect.Declarative`
  drives the rest of the lifecycle and `ImagePipe.Plug` owns the request spine.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Dialect,
      ImagePipe.Dialect.Declarative,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Response
    ],
    exports: [Resolver, Resolver.Static]

  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.IIIF.Config
  alias ImagePipe.Dialect.IIIF.Errors
  alias ImagePipe.Dialect.IIIF.Grammar
  alias ImagePipe.Dialect.IIIF.Path
  alias ImagePipe.Dialect.IIIF.PlanBuilder

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(%Plug.Conn{} = conn, config) do
    case Path.classify(conn) do
      {:redirect, _id, location} ->
        {:redirect, 303, location}

      {:info, id} ->
        with {:ok, source} <- resolve(id, config) do
          PlanBuilder.info_plan(source, Path.base_uri(conn) <> "/" <> URI.encode(id), config)
        end

      {:image, id, tokens} ->
        with {:ok, source} <- resolve(id, config),
             {:ok, parsed} <- parse_tokens(tokens) do
          PlanBuilder.image_plan(
            source,
            parsed,
            Keyword.put(config, :debug?, debug_requested?(conn))
          )
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  # `?debug=1` (also `?debug=true`) opts the response into `X-ImagePipe-*` debug
  # headers, honored only under the `allow_debug_headers: true` mount flag. The
  # IIIF path grammar has no free slot, so the trigger is an out-of-band query
  # param — an ImagePipe extension, not part of the IIIF spec. It is read
  # leniently: any non-true value (absent, `0`, `false`, garbage) disables it,
  # so a malformed flag never fails an otherwise-valid image request. IIIF has
  # no request signing, so the trigger is unprotected; see
  # docs/iiif_3_support_matrix.md.
  defp debug_requested?(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    Map.get(conn.query_params, "debug") in ["1", "true"]
  end

  defp resolve(id, config) do
    {module, resolver_opts} = Keyword.fetch!(config, :resolver)

    case module.resolve(id, resolver_opts) do
      {:ok, %_{} = source} -> {:ok, source}
      {:error, _reason} -> {:error, :not_found}
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
end
