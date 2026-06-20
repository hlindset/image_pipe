defmodule ImagePipe.Output.EncodeSearchPropertyTest do
  @moduledoc """
  Property invariants for the encode-quality search and the per-format resolution
  that feeds it. The search assumes byte size and SSIMULACRA2 score are
  non-decreasing in quality, but real encoders violate that locally — so these
  properties feed deliberately NON-MONOTONE curves (a monotone base plus random
  per-quality jitter) and assert only the invariants that hold regardless of
  monotonicity:

    * the winning quality is always inside `[min_quality, max_quality]`;
    * a `:size`/`max_bytes` `:hit` always fits the byte target;
    * a `:ssim2` `:hit` always clears `target - allowed_error`.

  Optimality is deliberately NOT asserted: under a non-monotone curve the binary
  search may land a step off the true boundary, which the module documents as
  acceptable best-effort behavior.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output

  @output_formats [:avif, :webp, :jpeg, :png]

  property "size: result quality is always within the bracket; a :hit fits the byte target" do
    check all {lo, hi} <- bracket(),
              target <- integer(1..200),
              size_curve <- curve(lo, hi, 1, 4000),
              max_iterations <- integer(1..12),
              max_runs: 80 do
      rqs = %RQS{objective: :size, target: target, min_quality: lo, max_quality: hi}
      encode_fun = size_encode_fun(size_curve)

      assert {:ok, bin, meta} =
               EncodeSearch.search(rqs, nil,
                 encode_fun: encode_fun,
                 max_iterations: max_iterations
               )

      assert meta.quality in lo..hi
      assert byte_size(bin) == meta.bytes
      if meta.outcome == :hit, do: assert(meta.bytes <= target)
    end
  end

  property "max_bytes alone: result quality is within [10, base]; a :hit fits the budget" do
    check all base <- integer(10..100),
              budget <- integer(1..5000),
              size_curve <- curve(10, base, 1, 4000),
              max_iterations <- integer(1..12),
              max_runs: 80 do
      encode_fun = size_encode_fun(size_curve)

      assert {:ok, bin, meta} =
               EncodeSearch.search(:none, budget,
                 encode_fun: encode_fun,
                 base_quality: base,
                 max_iterations: max_iterations
               )

      assert meta.quality in 10..base
      assert byte_size(bin) == meta.bytes
      if meta.outcome == :hit, do: assert(meta.bytes <= budget)
    end
  end

  property "ssim2: result quality is within the bracket; a :hit clears the tolerance band" do
    check all {lo, hi} <- bracket(),
              target <- float_in(1.0, 100.0),
              allowed_error <- float_in(0.0, 10.0),
              score_curve <- curve(lo, hi, 0, 100),
              max_iterations <- integer(1..12),
              max_runs: 80 do
      rqs = %RQS{
        objective: :ssim2,
        target: target,
        min_quality: lo,
        max_quality: hi,
        allowed_error: allowed_error
      }

      encode_fun = fn q -> {:ok, :binary.copy(<<0>>, q + 1)} end
      score_fun = score_fun(score_curve)

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rqs, nil,
                 encode_fun: encode_fun,
                 score_fun: score_fun,
                 max_iterations: max_iterations
               )

      assert meta.quality in lo..hi

      if meta.outcome == :hit do
        assert meta.score != nil
        assert meta.score >= target - allowed_error
      end
    end
  end

  property "Policy.resolve/2 yields a resolved search with min_quality <= max_quality" do
    check all {lo, hi} <- bracket(),
              format_min <- quality_map(),
              format_max <- quality_map(),
              objective <- member_of([:size, :ssim2]),
              negotiated_format <- member_of(@output_formats),
              max_runs: 100 do
      # A sane host configures per-format brackets that stay ordered under every
      # fallback combination (a covered min with an uncovered max falls back to
      # the base `hi`, and vice versa). Constrain each covered per-format value so
      # all four combinations remain ordered, so the property checks that the
      # per-format CLAMP preserves the invariant across format selection rather
      # than that resolve repairs contradictory config.
      {format_min, format_max} = order_per_format(format_min, format_max, lo, hi)

      search = %Output.QualitySearch{
        objective: objective,
        target: 50,
        min_quality: lo,
        max_quality: hi,
        format_min: format_min,
        format_max: format_max
      }

      policy = policy_for(search, negotiated_format)

      assert {:ok, %Resolved{quality_search: %RQS{} = resolved}} =
               Policy.resolve(policy, nil)

      assert resolved.min_quality <= resolved.max_quality
    end
  end

  # --- generators -----------------------------------------------------------

  # An ordered bracket within 1..100.
  defp bracket do
    bind(integer(1..100), fn lo ->
      bind(integer(lo..100), fn hi -> constant({lo, hi}) end)
    end)
  end

  # A possibly non-monotone curve over q in lo..hi: a monotone base ramp from
  # `base_lo` to `base_hi`, perturbed by per-quality jitter so locally the value
  # can dip below or jump above a neighbor — exactly the real-encoder violation
  # the search must tolerate. Returned as a %{quality => value} map.
  defp curve(lo, hi, base_lo, base_hi) do
    qualities = Enum.to_list(lo..hi)
    span = max(hi - lo, 1)
    jitter_mag = max(div(base_hi - base_lo, 6), 1)

    qualities
    |> Enum.map(fn _q -> integer(-jitter_mag..jitter_mag) end)
    |> fixed_list()
    |> map(fn jitters ->
      qualities
      |> Enum.zip(jitters)
      |> Map.new(fn {q, jitter} ->
        base = base_lo + div((q - lo) * (base_hi - base_lo), span)
        {q, clamp(base + jitter, base_lo, base_hi)}
      end)
    end)
  end

  defp size_encode_fun(size_curve) do
    fn q -> {:ok, :binary.copy(<<0>>, Map.fetch!(size_curve, q))} end
  end

  defp score_fun(score_curve) do
    fn bin -> Map.fetch!(score_curve, score_curve_key(score_curve, bin)) end
  end

  # The ssim2 encode_fun emits `q + 1` bytes, so byte_size - 1 recovers q to look
  # the score up. Keeps score keyed on the actual probed quality.
  defp score_curve_key(_score_curve, bin), do: byte_size(bin) - 1

  # Random per-format quality map over a subset of the output formats.
  defp quality_map do
    @output_formats
    |> Enum.map(fn format ->
      one_of([constant(nil), integer(1..100)])
      |> map(fn value -> {format, value} end)
    end)
    |> fixed_list()
    |> map(fn pairs ->
      pairs
      |> Enum.reject(fn {_format, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp float_in(lo, hi), do: map(integer(0..1000), fn n -> lo + n / 1000 * (hi - lo) end)

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)

  # Constrain each covered per-format value so every fallback combination against
  # the base bracket [lo, hi] stays ordered: a covered min is clamped to <= hi, a
  # covered max to >= lo, and a both-present pair is swapped into order.
  defp order_per_format(format_min, format_max, lo, hi) do
    {mins, maxes} =
      Enum.reduce(@output_formats, {format_min, format_max}, fn format, {mins, maxes} ->
        mins =
          case Map.get(mins, format) do
            min when is_integer(min) -> Map.put(mins, format, min(min, hi))
            nil -> mins
          end

        maxes =
          case Map.get(maxes, format) do
            max when is_integer(max) -> Map.put(maxes, format, max(max, lo))
            nil -> maxes
          end

        {mins, maxes}
      end)

    Enum.reduce(@output_formats, {mins, maxes}, fn format, {mins, maxes} ->
      case {Map.get(mins, format), Map.get(maxes, format)} do
        {min, max} when is_integer(min) and is_integer(max) and min > max ->
          {Map.put(mins, format, max), Map.put(maxes, format, min)}

        _other ->
          {mins, maxes}
      end
    end)
  end

  defp policy_for(search, format) do
    %Policy{
      mode: {:explicit, format},
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{},
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :strip,
      flatten_background: Color.white(),
      quality_search: search,
      max_bytes: nil
    }
  end
end
