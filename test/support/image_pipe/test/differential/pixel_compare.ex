defmodule ImagePipe.Test.Differential.PixelCompare do
  @moduledoc """
  Pure pixel-comparison primitives for differential conformance harnesses.
  Operates on decoded `Vix.Vips.Image` structs. Each band is read once
  to a raw row-major buffer (`write_to_binary/1`) and indexed in the BEAM, so a
  full-frame comparison costs two FFI reads instead of per-pixel FFI calls.
  """
  use Boundary, top_level?: true, deps: []

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @spec dims(VipsImage.t()) :: {pos_integer(), pos_integer()}
  def dims(image), do: {Image.width(image), Image.height(image)}

  @doc """
  Largest per-band **spatial** range (`max − min` over the pixels of a band), in
  8-bit-equivalent levels (0.0..255.0). A discrimination signal: a near-zero value
  means the image is spatially flat — a placement/crop error would move the window
  within a uniform field and produce identical pixels, so the fixture cannot detect
  it (e.g. the marker dead-region crops).

  Uses per-band stats deliberately: a spatially uniform `[200,180,60]` fill has a
  *band-byte* range of 140 (the cross-channel gamut) yet zero spatial variation, so
  band-byte range would mis-rate it as discriminating. `vips_stats` row 0 is the
  combined cross-band row (ignored); rows `1..bands` are per band, columns
  `0=min, 1=max`. Normalized by the band format max so 8- and 16-bit fixtures are
  comparable.
  """
  @spec spatial_contrast(VipsImage.t()) :: float()
  def spatial_contrast(image) do
    {:ok, stats} = Operation.stats(image)
    {:ok, bin} = VipsImage.write_to_binary(stats)
    vals = for <<v::native-float-64 <- bin>>, do: v

    max_band_range =
      1..Image.bands(image)
      |> Enum.map(fn band -> Enum.at(vals, band * 10 + 1) - Enum.at(vals, band * 10) end)
      |> Enum.max()

    max_band_range / format_max(VipsImage.format(image)) * 255.0
  end

  defp format_max(:VIPS_FORMAT_USHORT), do: 65_535.0
  defp format_max(:VIPS_FORMAT_SHORT), do: 32_767.0
  defp format_max(:VIPS_FORMAT_UINT), do: 4_294_967_295.0
  defp format_max(_), do: 255.0

  # A band sample's width in the raw `write_to_binary` buffer. USHORT (16-bit)
  # fixtures pack two bytes per sample; everything else the harness compares
  # (8-bit PNG decode) is one byte. Comparing raw *bytes* would split a 16-bit
  # sample into hi/lo halves and judge each as an 8-bit value, so a hair of 16-bit
  # noise reads as a structural blow-out in the low byte (#229) — hence the
  # per-format walk below.
  defp sample_bytes(:VIPS_FORMAT_USHORT), do: 2
  defp sample_bytes(_), do: 1

  # 8-bit-equivalent level → raw sample threshold for this band format, so one
  # tolerance vocabulary (0..255 levels) judges 8- and 16-bit fixtures alike
  # (USHORT: ×257, since 65535/255 = 257).
  defp raw_threshold(level, format), do: round(level * format_max(format) / 255.0)

  # Inverse of raw_threshold: a raw sample delta back to 8-bit-equivalent levels.
  defp to_levels(raw, format), do: round(raw / (format_max(format) / 255.0))

  @spec same_dims?(VipsImage.t(), VipsImage.t()) :: boolean()
  def same_dims?(a, b), do: dims(a) == dims(b)

  @doc """
  Count of band-samples whose absolute delta exceeds `threshold`, in 8-bit-equivalent
  levels (per-sample counting upper-bounds pixel outliers — the stricter choice). A
  16-bit (USHORT) sample is reconstructed and judged in 16-bit space, then compared
  against `threshold` scaled into that space, so the count is per *sample*, not per
  raw byte. Raises `ArgumentError` if the two images differ in dimensions or band
  layout.
  """
  @spec outliers(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: non_neg_integer()
  def outliers(a, b, threshold) do
    unless same_dims?(a, b) do
      raise ArgumentError, "dimension mismatch: #{inspect(dims(a))} vs #{inspect(dims(b))}"
    end

    {:ok, ab} = VipsImage.write_to_binary(a)
    {:ok, bb} = VipsImage.write_to_binary(b)

    unless byte_size(ab) == byte_size(bb) do
      raise ArgumentError, "band layout mismatch: #{byte_size(ab)} vs #{byte_size(bb)}"
    end

    format = VipsImage.format(a)
    count_outliers(format, ab, bb, raw_threshold(threshold, format), 0)
  end

  @doc """
  Fraction (0.0..1.0) of band-samples whose absolute delta exceeds `threshold` — a
  whole-frame divergence metric. The denominator is the sample count (USHORT bands
  carry one sample per two bytes), matching `outliers/3`. Raises on dimension/band-
  layout mismatch.
  """
  @spec fraction_over(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: float()
  def fraction_over(a, b, threshold) do
    {:ok, ab} = VipsImage.write_to_binary(a)

    case div(byte_size(ab), sample_bytes(VipsImage.format(a))) do
      0 -> 0.0
      samples -> outliers(a, b, threshold) / samples
    end
  end

  @default_thresholds [2, 16, 32]

  @typedoc """
  An accepted-and-monitored divergence's expected band (authored on a `:diverges`
  constellation). `max_delta` and `outliers` are the two-sided bands the live diff
  must fall within; `reason`/`issue` are documentation carried alongside.
  """
  @type divergence_map :: %{
          required(:reason) => String.t(),
          required(:max_delta) => Range.t(),
          required(:outliers) => Range.t(),
          optional(:issue) => integer()
        }

  @doc """
  Classify an accepted divergence against its expected two-sided band — the shared
  gate for `verdict: :diverges` constellations. Returns `:ok` when both the
  per-sample `max_delta` and the Δ2 `outliers` count from `diagnose/3` fall inside
  their authored bands.

  On a miss it reports *which* metric and *which* bound was crossed:

  - `:above_ceiling` → the divergence **grew** (a likely regression — investigate).
  - `:below_floor` → the divergence **shrank/vanished** (a libvips update may have
    made it match — consider promoting the case back to `:equal`).

  The two images must be dimension/band comparable (the conformance test asserts
  same dims first); a `:diverges` case is by definition a same-frame pixel diff.
  """
  @spec classify_divergence(VipsImage.t(), VipsImage.t(), divergence_map()) ::
          :ok
          | {:error, :below_floor | :above_ceiling,
             %{metric: :max_delta | :outliers, value: non_neg_integer(), band: Range.t()}}
  def classify_divergence(out, fixture, %{max_delta: md_band, outliers: ol_band}) do
    diag = diagnose(out, fixture, [2])

    with :ok <- check_band(:max_delta, diag.max_delta, md_band) do
      check_band(:outliers, Map.fetch!(diag.over, 2), ol_band)
    end
  end

  defp check_band(metric, value, band) do
    cond do
      value < band.first -> {:error, :below_floor, %{metric: metric, value: value, band: band}}
      value > band.last -> {:error, :above_ceiling, %{metric: metric, value: value, band: band}}
      true -> :ok
    end
  end

  @default_radius 1
  @default_value_tol 2
  @default_overshoot 8

  @doc """
  Count of differing band-samples **not** explainable by the reference's local
  neighborhood — a neighborhood-aware triage signal (informational, never a gate)
  that separates resampling/phase artifacts from genuine geometry shifts.

  A differing sample is a *resampling artifact* (haloing/ringing) when its value is a
  blend of its local neighborhood: it lies within `[local_min − ε, local_max + ε]` of
  the corresponding window (square, half-width `radius`) in the reference image `b`
  (`ε` = `overshoot`, absorbing Lanczos overshoot). A *geometry difference* moves an
  edge, producing samples whose values fall outside that range — those are counted.
  Only samples differing by more than `value_tol` (8-bit-equivalent levels) are
  considered. `b` is the reference (the differential fixture); `a` is the candidate.

  `radius` *defines* "negligible geometry difference": a ≤`radius`-px hard shift is
  spatially indistinguishable from sub-pixel resampling, so keep it small (1–2) — a
  ≥2px shift then reads as non-zero, sub-pixel/phase skew as ≈0. When an image axis
  is smaller than the requested window, the neighborhood clips to that axis.

  Opts: `radius` (default `1`), `value_tol` (default `2` levels), `overshoot`
  (default `8` levels). Raises on dimension/band-layout mismatch.
  """
  @spec structural_outliers(VipsImage.t(), VipsImage.t(), keyword()) :: non_neg_integer()
  def structural_outliers(a, b, opts \\ []) do
    unless same_dims?(a, b) do
      raise ArgumentError, "dimension mismatch: #{inspect(dims(a))} vs #{inspect(dims(b))}"
    end

    radius = Keyword.get(opts, :radius, @default_radius)
    value_tol = Keyword.get(opts, :value_tol, @default_value_tol)
    overshoot = Keyword.get(opts, :overshoot, @default_overshoot)
    format = VipsImage.format(a)

    requested_window = 2 * radius + 1
    window_width = min(requested_window, Image.width(b))
    window_height = min(requested_window, Image.height(b))
    window_samples = window_width * window_height
    lo_img = Operation.rank!(b, window_width, window_height, 0)
    hi_img = Operation.rank!(b, window_width, window_height, window_samples - 1)

    {:ok, ab} = VipsImage.write_to_binary(a)
    {:ok, bb} = VipsImage.write_to_binary(b)
    {:ok, lob} = VipsImage.write_to_binary(lo_img)
    {:ok, hib} = VipsImage.write_to_binary(hi_img)

    unless byte_size(ab) == byte_size(bb) do
      raise ArgumentError, "band layout mismatch: #{byte_size(ab)} vs #{byte_size(bb)}"
    end

    count_structural(
      format,
      ab,
      bb,
      lob,
      hib,
      raw_threshold(value_tol, format),
      raw_threshold(overshoot, format),
      0
    )
  end

  # A differing candidate sample (|a − b| > value_tol) is structural when it falls
  # outside the reference neighborhood's [min − ε, max + ε]. Walks all four raw
  # buffers (candidate, reference, reference local-min, reference local-max) in
  # lockstep, per-format like the other scanners.
  defp count_structural(_format, <<>>, <<>>, <<>>, <<>>, _vt, _eps, acc), do: acc

  defp count_structural(
         :VIPS_FORMAT_USHORT,
         <<av::native-unsigned-16, ar::binary>>,
         <<bv::native-unsigned-16, br::binary>>,
         <<lo::native-unsigned-16, lr::binary>>,
         <<hi::native-unsigned-16, hr::binary>>,
         vt,
         eps,
         acc
       ) do
    acc = bump_structural(av, bv, lo, hi, vt, eps, acc)
    count_structural(:VIPS_FORMAT_USHORT, ar, br, lr, hr, vt, eps, acc)
  end

  defp count_structural(
         format,
         <<av, ar::binary>>,
         <<bv, br::binary>>,
         <<lo, lr::binary>>,
         <<hi, hr::binary>>,
         vt,
         eps,
         acc
       ) do
    acc = bump_structural(av, bv, lo, hi, vt, eps, acc)
    count_structural(format, ar, br, lr, hr, vt, eps, acc)
  end

  defp bump_structural(av, bv, lo, hi, vt, eps, acc) do
    if abs(av - bv) > vt and (av < lo - eps or av > hi + eps), do: acc + 1, else: acc
  end

  @doc """
  Single-pass triage summary for a live-vs-fixture comparison: dims, band layout,
  the maximum absolute sample delta, and a sample count over each threshold — all
  in 8-bit-equivalent levels (USHORT samples are reconstructed and normalized, so
  8- and 16-bit fixtures share one vocabulary).

  Returns a map:

      %{
        dims: {dims(a), dims(b)},
        bands: {bands(a), bands(b)},
        comparable: boolean(),
        max_delta: non_neg_integer() | nil,
        over: %{threshold => count}
      }

  `max_delta` is the key skew-vs-structural signal: a diffuse libvips-version
  resampling seam stays low (tens of levels), while a placement/crop shift
  misaligns high-contrast edges toward ~255. When the two images differ in
  dimensions or band layout they cannot be compared band-for-band (a band-count
  divergence is itself a finding — see #220), so `comparable` is `false`,
  `max_delta` is `nil`, and `over` is empty; `dims`/`bands` are still reported.
  """
  @spec diagnose(VipsImage.t(), VipsImage.t(), [non_neg_integer()]) :: map()
  def diagnose(a, b, thresholds \\ @default_thresholds) do
    da = dims(a)
    db = dims(b)
    ba = Image.bands(a)
    bb = Image.bands(b)
    comparable = da == db and ba == bb
    base = %{dims: {da, db}, bands: {ba, bb}, comparable: comparable}

    if comparable do
      {:ok, abin} = VipsImage.write_to_binary(a)
      {:ok, bbin} = VipsImage.write_to_binary(b)
      format = VipsImage.format(a)
      pairs = Enum.map(thresholds, &{&1, raw_threshold(&1, format)})
      {max_raw, over} = scan(format, abin, bbin, pairs, 0, Map.new(thresholds, &{&1, 0}))
      Map.merge(base, %{max_delta: to_levels(max_raw, format), over: over})
    else
      Map.merge(base, %{max_delta: nil, over: %{}})
    end
  end

  # Counts band-samples (not pixels) whose absolute delta exceeds the raw threshold.
  # Per-sample counting upper-bounds pixel outliers — the stricter choice. A USHORT
  # sample is reconstructed from its two native-endian bytes so the delta is judged
  # in 16-bit space, not split across hi/lo bytes (#229).
  defp count_outliers(_format, <<>>, <<>>, _t, acc), do: acc

  defp count_outliers(
         :VIPS_FORMAT_USHORT,
         <<av::native-unsigned-16, ar::binary>>,
         <<bv::native-unsigned-16, br::binary>>,
         t,
         acc
       ) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(:VIPS_FORMAT_USHORT, ar, br, t, acc)
  end

  defp count_outliers(format, <<av, ar::binary>>, <<bv, br::binary>>, t, acc) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(format, ar, br, t, acc)
  end

  # One pass over both raw buffers, tracking the max raw sample delta and per-level
  # counts. `pairs` carries each {level, raw_threshold} so counts stay keyed by the
  # caller's 8-bit-equivalent levels while the comparison runs in raw sample units.
  defp scan(_format, <<>>, <<>>, _pairs, max_raw, counts), do: {max_raw, counts}

  defp scan(
         :VIPS_FORMAT_USHORT,
         <<av::native-unsigned-16, ar::binary>>,
         <<bv::native-unsigned-16, br::binary>>,
         pairs,
         max_raw,
         counts
       ) do
    delta = abs(av - bv)
    scan(:VIPS_FORMAT_USHORT, ar, br, pairs, max(max_raw, delta), bump(pairs, delta, counts))
  end

  defp scan(format, <<av, ar::binary>>, <<bv, br::binary>>, pairs, max_raw, counts) do
    delta = abs(av - bv)
    scan(format, ar, br, pairs, max(max_raw, delta), bump(pairs, delta, counts))
  end

  defp bump(pairs, delta, counts) do
    Enum.reduce(pairs, counts, fn {level, raw}, acc ->
      if delta > raw, do: Map.update!(acc, level, &(&1 + 1)), else: acc
    end)
  end
end
