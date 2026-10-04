defmodule ImagePipe.Output.EncodeSearchPropertyTest do
  @moduledoc """
  Property invariants for the encode-quality search. The search assumes byte size and SSIMULACRA2 score are
  non-decreasing in quality, but real encoders violate that locally — so these
  properties feed deliberately NON-MONOTONE curves (a monotone base plus random
  per-quality jitter) and assert only the invariants that hold regardless of
  monotonicity:

    * the winning quality is always inside `[min_quality, max_quality]`;
    * a `max_bytes` `:hit` always fits the byte target;
    * a `:ssim2` `:hit` always clears `target - allowed_error`.

  Optimality is deliberately NOT asserted: under a non-monotone curve the binary
  search may land a step off the true boundary, which the module documents as
  acceptable best-effort behavior.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

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
      rqs = %RQS.Ssimulacra2{
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

  # --- helpers --------------------------------------------------------------

  defp float_in(lo, hi), do: map(integer(0..1000), fn n -> lo + n / 1000 * (hi - lo) end)

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)
end
