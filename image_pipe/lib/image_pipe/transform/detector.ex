defmodule ImagePipe.Transform.Detector do
  @moduledoc """
  Behaviour for detectors that find faces and objects for `detect` and
  `anchor=smart-face` crops.

  The default detector, `ImagePipe.Transform.Detector.Composite`, sends the
  `face` class to `ImagePipe.Transform.Detector.ImageVision.Face` and object
  classes to `ImagePipe.Transform.Detector.ImageVision.Objects`. To use
  another model or a remote service, implement this behaviour and set the
  `:detector` option of `ImagePipe.config/1` to your module:

      config = ImagePipe.config(sources: sources, detector: MyApp.Detector)

  [Writing a custom detector](custom-detectors.md) walks through an
  implementation. [Content-aware cropping](content-aware-gravity.md) explains
  how the regions place the crop.

  ## Callback options

  Every callback receives a keyword list. Its `:classes` key holds the
  requested class names, in their URL spelling (`"face"`,
  `"traffic_light"`), or `:all`. Other keys may be present. A detector
  ignores the keys it doesn't use. `supported_classes/1` is called with `[]`.

  ## Regions

  `detect/2` returns a list of `t:region/0` maps.

  - `label` must be one of the requested classes, or any class when
    `:classes` is `:all`. ImagePipe doesn't filter the regions, so a region
    with another label still moves the crop. Request weights such as
    `face:3` apply by label.
  - `box` must hold four numbers. Any other shape makes the whole result a
    detection error.
  - A box with no width or height, or one that extends past the image's
    edges, is ignored.
  - `score` doesn't affect the crop, so a low-confidence region moves it as
    much as a confident one.

  ## Errors

  `detect/2` returns `{:error, reason}` instead of raising. With
  `detector_required: true`, any error fails the request with `500`. With
  `detector_required: false`, the crop falls back to attention cropping, and
  the response depends on `reason`:

  - `{:detector, :unavailable}` means the detector can't run in this build,
    for example because an optional dependency is missing. The response is
    cached like any other. `identity/1` must return a different value while
    the detector is unavailable, or the fallback is stored under the
    identity of the working model.
  - Any other reason is a detection error. The response is sent with
    `Cache-Control: no-store` and no ETag, and isn't stored.

  A detector that runs several models returns an error when any of them
  fails, not the regions the others found. A partial result is cached as if
  it were complete.

  `anchor=smart-face` falls back to attention cropping on any error, whatever
  `:detector_required` is.

  ## Availability and readiness

  `available?/1` and the optional `ready?/1` are checked before a request
  fetches its source, only when `:detector_required` is `true` and the
  request uses `detect`:

  - `available?/1` returning `false` fails the request with `501`.
  - `ready?/1` returning `false` fails it with `503`. Without `ready?/1`,
    the detector is ready whenever it is available.

  With `detector_required: false`, requests call `detect/2` directly.
  `ImagePipe.Transform.Detector.Warmup` also skips a detector whose
  `available?/1` returns `false`.

  ## Identity

  `identity/1` returns `{module, term}`, which becomes part of the cache key
  and ETag of every response that used the detector. Change the term when
  the model changes, for example by including the model version, so crops
  made by the old model are replaced. It must return the same value for the
  same model and options. Keep it free of secrets: telemetry handlers can
  receive it.
  """

  @typedoc """
  A detected region of interest.

  `box` is `{x, y, width, height}` in pixels of the image passed to
  `c:detect/2`, measured from its top-left corner (x grows right, y grows
  down).
  """
  @type region :: %{
          label: String.t(),
          score: float(),
          box: {number(), number(), number(), number()}
        }

  @doc """
  Returns every class name this detector can produce, in the URL spelling.

  Called with `[]` to route classes and to reject unknown classes with `400`.
  It must not load a model, and must return the full list even when
  `available?/1` is `false`.
  """
  @callback supported_classes(opts :: keyword()) :: [String.t()]

  @doc """
  Detects regions in `image` for the classes in `opts[:classes]`.

  Returns `{:ok, regions}`, where an empty list means nothing was found, or
  `{:error, reason}`. See "Regions" and "Errors" above.
  """
  @callback detect(image :: Vix.Vips.Image.t(), opts :: keyword()) ::
              {:ok, [region()]} | {:error, term()}

  @doc """
  Returns whether the detector can run in this build, for example whether
  its optional dependency is loaded.
  """
  @callback available?(opts :: keyword()) :: boolean()

  @doc "Returns the detector's cache identity. See \"Identity\" above."
  @callback identity(opts :: keyword()) :: {module(), term()}

  @doc """
  Loads or downloads models ahead of the first request.

  Optional. `ImagePipe.Transform.Detector.Warmup` calls it with its `:opts`
  plus `:classes`. It returns `:ok` or `{:error, reason}`. The worker logs
  and retries errors.
  """
  @callback warmup(opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Returns whether `detect/2` can run without first downloading model files.

  Optional. Without it, a detector is ready whenever `available?/1` is
  `true`. See "Availability and readiness" above.
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
