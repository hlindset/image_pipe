defmodule ImagePipe.Plan.Output.QualitySearch do
  @moduledoc """
  Builds a per-request autoquality search struct
  (`Size`/`Ssimulacra2`/`Butteraugli`) from resolved neutral config, optionally
  overlaid with URL-supplied fields. Product-neutral: every dialect (imgproxy via
  `build/3` with URL fields, IIIF/TwicPics via `from_config/1` with none) shares
  this one builder, so the struct shape and the per-metric fallbacks live in one
  place.

  Per-metric target and `allowed_error` fallbacks come from the config maps
  (`ImagePipe.Config` seeds `autoquality_target`/`autoquality_allowed_error` for
  the perceptual metrics), so there are no built-in constants here. `:size` has no
  default target — a byte budget must be supplied (URL or config) or `build/3`
  returns a missing-target error.
  """

  alias ImagePipe.Plan.Output.QualitySearch.{Butteraugli, Metric, Size, Ssimulacra2}

  @doc """
  Config-only entry point: select the metric from `autoquality_method` and build.
  `:none` short-circuits to `{:ok, :none}`. No URL fields.
  """
  @spec from_config(keyword()) :: {:ok, struct() | :none} | {:error, term()}
  def from_config(config) do
    case Keyword.get(config, :autoquality_method, :none) do
      :none -> {:ok, :none}
      metric -> build(metric, [], config)
    end
  end

  @doc "Build a search struct for an already-decided metric, URL fields over config."
  @spec build(:size | :ssimulacra2 | :butteraugli, keyword(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def build(:size, fields, config) do
    with {:ok, target} <- resolve_target(:size, fields, config) do
      {:ok,
       %Size{
         target: target,
         min_quality: Keyword.get(config, :autoquality_min_quality, 70),
         max_quality: Keyword.get(config, :autoquality_max_quality, 80),
         url_min_quality: Keyword.get(fields, :min_quality),
         url_max_quality: Keyword.get(fields, :max_quality),
         format_min: Keyword.get(config, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(config, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(config, :autoquality_max_resolution, 0)
       }}
    end
  end

  def build(:ssimulacra2, fields, config),
    do: build_perceptual(Ssimulacra2, :ssimulacra2, fields, config)

  def build(:butteraugli, fields, config),
    do: build_perceptual(Butteraugli, :butteraugli, fields, config)

  defp build_perceptual(struct_mod, metric, fields, config) do
    with {:ok, target} <- resolve_target(metric, fields, config) do
      {:ok,
       struct(struct_mod, %{
         target: target,
         min_quality: Keyword.get(config, :autoquality_min_quality, 70),
         max_quality: Keyword.get(config, :autoquality_max_quality, 80),
         url_min_quality: Keyword.get(fields, :min_quality),
         url_max_quality: Keyword.get(fields, :max_quality),
         allowed_error: resolve_allowed_error(metric, fields, config),
         format_min: Keyword.get(config, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(config, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(config, :autoquality_max_resolution, 0)
       })}
    end
  end

  # URL arg → per-metric config map. The config map is always seeded for the
  # perceptual metrics, so no built-in constant fallback remains. 0/0.0 are truthy
  # in Elixir, so a configured 0 is honored by the `||`.
  defp resolve_allowed_error(metric, fields, config) do
    Keyword.get(fields, :allowed_error) ||
      Map.get(Keyword.get(config, :autoquality_allowed_error, %{}), metric)
  end

  # URL arg → per-metric config map → missing-target error (`:size` only, since the
  # perceptual metrics are seeded).
  defp resolve_target(metric, fields, config) do
    config_target = Map.get(Keyword.get(config, :autoquality_target, %{}), metric)

    case Keyword.get(fields, :target, config_target) do
      nil -> {:error, {:invalid_option, :autoquality, :missing_target}}
      target -> validate_target_range(metric, target)
    end
  end

  defp validate_target_range(:size, target) when is_integer(target) and target > 0,
    do: {:ok, target}

  defp validate_target_range(:size, target),
    do: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}

  defp validate_target_range(metric, target) do
    {lo, hi} = Metric.target_range(metric)

    if is_number(target) and target >= lo and target <= hi,
      do: {:ok, target},
      else: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}
  end
end
