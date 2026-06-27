defmodule ImagePipe.Plan.Output.QualitySearch.Metric do
  @moduledoc """
  Product-neutral facts about a perceptual autoquality metric, keyed by its
  identity atom. These are intrinsic mathematical properties of the metric — not
  dialect concepts — so they live in the neutral Plan namespace that both the
  `ImagePipe.Output` runtime and the dialect parsers may depend on, giving each
  fact a single definition.

  - `target_range/1` — the valid `{lo, hi}` band a requested target must fall in:
    SSIMULACRA2's `0`–`100` score, butteraugli's `0.0`–`25.0` distance (libvips
    `jxlsave`'s own `distance` bound).
  - `direction/1` — whether a higher score is better (SSIMULACRA2) or a lower
    distance is better (butteraugli), orienting the search loop's band walk.

  `:size` (byte-budget autoquality) is not a perceptual metric and has no range or
  direction here; the parser validates its byte target directly.
  """

  @type id :: :ssimulacra2 | :butteraugli
  @type direction :: :higher_better | :lower_better

  @doc "Valid `{lo, hi}` target band for the metric."
  @spec target_range(id()) :: {number(), number()}
  def target_range(:ssimulacra2), do: {0, 100}
  def target_range(:butteraugli), do: {0.0, 25.0}

  @doc "Whether higher (score) or lower (distance) values indicate better quality."
  @spec direction(id()) :: direction()
  def direction(:ssimulacra2), do: :higher_better
  def direction(:butteraugli), do: :lower_better
end
