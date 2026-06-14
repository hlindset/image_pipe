defmodule ImagePipe.Parser.IIIF.PlanBuilder do
  @moduledoc false

  alias ImagePipe.Parser.IIIF.InfoRenderer
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Bitonal
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Gray
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response

  @doc """
  Builds an `%ImagePipe.Plan{}` for a IIIF info.json request.

  `source` is an `ImagePipe.Plan.Source.*` struct already resolved by the caller.
  `id_uri` is the absolute base URI for the image identifier (the IIIF `id` field).
  `opts` accepts `formats`, `qualities`, `tile_size`.
  """
  @spec info_plan(Plan.Source.t(), String.t(), keyword()) :: {:ok, Plan.t()}
  def info_plan(source, id_uri, opts) do
    params = %{
      id: id_uri,
      level: "level2",
      offers: [
        {"application/ld+json;profile=\"http://iiif.io/api/image/3/context.json\"",
         ["application/ld+json"]}
      ],
      formats: Keyword.get(opts, :formats, [:jpg, :png, :webp, :avif]),
      qualities: Keyword.get(opts, :qualities, [:default, :color, :gray, :bitonal]),
      tile_size: Keyword.get(opts, :tile_size, 512)
    }

    {:ok,
     %Plan{
       source: source,
       pipelines: [],
       output: nil,
       auto_rotate: false,
       response: %Response{},
       render: {:custom, InfoRenderer, params}
     }}
  end

  @doc """
  Builds an `%ImagePipe.Plan{}` for a IIIF image request.

  `source` is an `ImagePipe.Plan.Source.*` struct already resolved by the caller.
  `tokens` is a map with keys `:region`, `:size`, `:rotation`, `:quality`, `:format`
  carrying the typed grammar values produced by `ImagePipe.Parser.IIIF.Grammar`.
  `opts` accepts `auto_rotate: boolean()` (default `false`).
  """
  @spec image_plan(ImagePipe.Plan.Source.t(), map(), keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def image_plan(source, tokens, opts \\ []) do
    auto_rotate = Keyword.get(opts, :auto_rotate, false)
    max_width = Keyword.get(opts, :max_width)

    bounds = %{
      max_width: max_width,
      max_height: Keyword.get(opts, :max_height) || max_width,
      max_area: Keyword.get(opts, :max_area)
    }

    with {:ok, region_ops} <- region_operations(tokens.region),
         {:ok, size_ops} <- size_operations(tokens.size, bounds),
         {:ok, rotation_ops} <- rotation_operations(tokens.rotation),
         {:ok, quality_ops} <- quality_operations(tokens.quality),
         {:ok, output} <- output_plan(tokens.format) do
      operations = region_ops ++ size_ops ++ rotation_ops ++ quality_ops

      {:ok,
       %Plan{
         source: source,
         auto_rotate: auto_rotate,
         pipelines: [%Pipeline{operations: operations}],
         output: output,
         response: %Response{}
       }}
    end
  end

  defp region_operations(:full), do: {:ok, []}

  defp region_operations(:square) do
    with {:ok, op} <-
           Operation.crop_guided(
             :full_axis,
             :full_axis,
             {:anchor, :center, :center},
             aspect_ratio: {:ratio, 1, 1}
           ) do
      {:ok, [op]}
    end
  end

  defp region_operations({:px, x, y, w, h}) do
    with {:ok, op} <- Operation.crop_region({:px, x}, {:px, y}, {:px, w}, {:px, h}) do
      {:ok, [op]}
    end
  end

  defp region_operations({:pct, xr, yr, wr, hr}) do
    with {:ok, op} <- Operation.crop_region(xr, yr, wr, hr) do
      {:ok, [op]}
    end
  end

  defp size_operations({:max, up?}, bounds) do
    with {:ok, op} <-
           Operation.resize(
             :fit,
             :auto,
             :auto,
             [enlargement: enlargement(up?, :deny)] ++ bound_opts(bounds)
           ) do
      {:ok, [op]}
    end
  end

  defp size_operations({:w, w, up?}, bounds) do
    with {:ok, op} <-
           Operation.resize(
             :fit,
             {:px, w},
             :auto,
             [enlargement: enlargement(up?, :reject)] ++ bound_opts(bounds)
           ) do
      {:ok, [op]}
    end
  end

  defp size_operations({:h, h, up?}, bounds) do
    with {:ok, op} <-
           Operation.resize(
             :fit,
             :auto,
             {:px, h},
             [enlargement: enlargement(up?, :reject)] ++ bound_opts(bounds)
           ) do
      {:ok, [op]}
    end
  end

  defp size_operations({:wh, w, h, up?}, bounds) do
    with {:ok, op} <-
           Operation.resize(
             :stretch,
             {:px, w},
             {:px, h},
             [enlargement: enlargement(up?, :reject)] ++ bound_opts(bounds)
           ) do
      {:ok, [op]}
    end
  end

  defp size_operations({:confined, w, h, up?}, bounds) do
    with {:ok, op} <-
           Operation.resize(
             :fit,
             {:px, w},
             {:px, h},
             [enlargement: enlargement(up?, :reject)] ++ bound_opts(bounds)
           ) do
      {:ok, [op]}
    end
  end

  defp size_operations({:pct, {:ratio, num, den}, up?}, bounds) do
    zoom = num / den

    with {:ok, op} <-
           Operation.resize(
             :fit,
             :auto,
             :auto,
             [zoom_x: zoom, zoom_y: zoom, enlargement: enlargement(up?, :reject)] ++
               bound_opts(bounds)
           ) do
      {:ok, [op]}
    end
  end

  defp bound_opts(%{max_width: mw, max_height: mh, max_area: ma}) do
    [max_width: mw, max_height: mh, max_area: ma]
  end

  defp rotation_operations({false, 0}), do: {:ok, []}
  defp rotation_operations({true, 0}), do: {:ok, [%Flip{axis: :horizontal}]}

  defp rotation_operations({mirror, angle}) do
    with {:ok, op} <- Operation.rotate(angle, mirror) do
      {:ok, [op]}
    end
  end

  defp quality_operations(quality) when quality in [:default, :color], do: {:ok, []}
  defp quality_operations(:gray), do: {:ok, [%Gray{}]}
  defp quality_operations(:bitonal), do: {:ok, [%Bitonal{}]}

  defp output_plan(:jpg), do: {:ok, %Output{mode: {:explicit, :jpeg}}}
  defp output_plan(:png), do: {:ok, %Output{mode: {:explicit, :png}}}
  defp output_plan(:webp), do: {:ok, %Output{mode: {:explicit, :webp}}}
  defp output_plan(:avif), do: {:ok, %Output{mode: {:explicit, :avif}}}

  defp enlargement(true, _fallback), do: :allow
  defp enlargement(false, fallback), do: fallback
end
