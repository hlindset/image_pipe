defmodule ImagePipe.Transform.Detector do
  @moduledoc """
  Host-implementable content detection for content-aware gravity.

  Detectors translate image content into product-neutral regions. The default
  adapter wraps the optional `image_vision` dependency; hosts may inject their
  own. Return values cross a host boundary and are validated structurally before
  use.
  """

  @typedoc """
  A detected region of interest.

  `box` is `{x, y, width, height}` in absolute top-left pixel coordinates of the
  input image (x grows right, y grows down). Host-written detectors must use this
  same convention so gravity targeting agrees across implementations.
  """
  @type region :: %{
          label: String.t(),
          score: float(),
          box: {number(), number(), number(), number()}
        }

  @doc """
  The class names this detector can produce, in the URL-facing spelling.

  Used for routing and availability checks. Must not load a model and must return
  the full vocabulary even when an optional dependency is absent or `available?/1`
  is `false`.
  """
  @callback supported_classes(opts :: keyword()) :: [String.t()]

  @doc """
  Detect regions of interest.

  `opts[:classes]` is a list of URL-facing class names or `:all`. Return only
  regions whose `label` is requested; `:all` allows any class. The caller trusts
  these labels for focal targeting and telemetry. The bundled `Composite` routes
  each class to its child detector, and the object adapter filters its results.

  A detector that combines several models must return an error when any of
  them fails, rather than the regions the others found. Callers don't cache a
  result that follows a detection error, but they do cache a partial one.
  """
  @callback detect(image :: Vix.Vips.Image.t(), opts :: keyword()) ::
              {:ok, [region()]} | {:error, term()}

  @doc "Whether the detector can run now (e.g. the optional dependency is loaded)."
  @callback available?(opts :: keyword()) :: boolean()

  @doc "Stable identity for cache-key material."
  @callback identity(opts :: keyword()) :: {module(), term()}

  @doc "Optionally pre-load models so the first request avoids download cost."
  @callback warmup(opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Whether `detect/2` can run without first downloading model files.

  Optional. Without it, a detector is ready whenever `available?/1` is true.
  Mounts with `detector_required: true` reject detection requests with `503`
  while it is false.
  """
  @callback ready?(opts :: keyword()) :: boolean()

  @optional_callbacks warmup: 1, ready?: 1

  @doc """
  Invoke the optional `warmup/1` callback if the detector implements it, else `:ok`.

  The callback is optional for host-provided detectors, so its presence is checked
  at this boundary.
  """
  @spec warmup(module(), keyword()) :: :ok | {:error, term()}
  def warmup(module, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :warmup, 1),
      do: module.warmup(opts),
      else: :ok
  end

  @doc """
  Invoke the optional `ready?/1` callback if the detector implements it, else
  `available?/1`.
  """
  @spec ready?(module(), keyword()) :: boolean()
  def ready?(module, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :ready?, 1),
      do: module.ready?(opts),
      else: module.available?(opts)
  end
end
