defmodule ImagePipe.Output.NativeJxlSearch do
  @moduledoc """
  Native JPEG XL autoquality strategy: libvips drives `jxlsave`'s `distance` knob
  directly, so there is no external measurement and no band search.

  Selected at resolve time for `(butteraugli, :jpeg_xl)`
  (`ImagePipe.Output.ResolvedQualitySearch.NativeJxlButteraugli`) and dispatched
  from `ImagePipe.Output.EncodeSearch.run/3`, which keeps the unified
  `{:ok, binary(), EncodeSearch.meta()}` execution contract. The distance target is
  clamped into the `[min_quality, max_quality]` Q-bracket via the libjxl Q→distance
  mapping (`ImagePipe.Output.JxlDistance`); `max_bytes` is honored by geometrically
  raising distance until the bytes fit (or the 25.0 ceiling), emitting the same
  `[:encode, :search]` span as the external search so observers read one stage.
  """

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.JxlDistance
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Telemetry

  @native_distance_max 25.0

  @doc """
  Execute the native-JXL strategy for a resolved `NativeJxlButteraugli` search.
  Returns the encoded buffer and a `meta` matching `EncodeSearch.meta/0`.
  """
  @spec run(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, binary(), EncodeSearch.meta()} | {:error, term()}
  def run(
        image,
        %Resolved{quality_search: %RQS.NativeJxlButteraugli{} = nqs} = resolved,
        opts
      ) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])
    native_jxl_butteraugli(image, nqs, resolved.max_bytes, jxl_effort(resolved), telemetry_opts)
  end

  # JXL effort: the negotiated JxlOptions.effort, defaulting to libvips' 7 when unset.
  defp jxl_effort(%Resolved{encoder_options: %ImagePipe.Plan.Output.JxlOptions{effort: e}}),
    do: e || 7

  defp jxl_effort(%Resolved{}), do: 7

  # libvips drives JXL `distance` directly: there is no external measure and no
  # band loop. We clamp the target into the Q-bracket's distance range, then
  # either encode once (no max_bytes) or degrade distance until the bytes fit.
  defp native_jxl_butteraugli(image, nqs, max_bytes, effort, telemetry_opts) do
    # Q-bracket → distance bracket; clamp the target. `dist` is decreasing in Q,
    # so max_quality is the distance floor (lowest distance / highest quality
    # allowed) and min_quality is the distance ceiling.
    dist_floor = JxlDistance.from_quality(nqs.max_quality)
    dist_ceil = JxlDistance.from_quality(nqs.min_quality)
    effective = nqs.target |> max(dist_floor) |> min(dist_ceil)

    Telemetry.span(telemetry_opts, [:encode, :search], native_start_meta(nqs, max_bytes), fn ->
      result = native_encode(image, effective, effort, max_bytes)
      {result, native_stop_meta(result)}
    end)
  end

  defp native_encode(image, distance, effort, nil) do
    with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance, effort) do
      {:ok, bin, native_meta(bin, :native, nil)}
    end
  end

  defp native_encode(image, distance, effort, max_bytes) do
    native_descend(image, distance, effort, max_bytes)
  end

  # Raise distance (degrade) from the clamped target until bytes fit or we hit the
  # distance ceiling. Coarse geometric steps; max_bytes is the hard cap.
  # `effective` is always <= dist_ceil = from_quality(min_quality) <= ~14.5
  # (min_quality >= 1), and `min/2` caps each step at exactly 25.0, so the
  # recursion saturates at @native_distance_max in finite steps.
  defp native_descend(image, distance, effort, max_bytes) do
    with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance, effort) do
      cond do
        byte_size(bin) <= max_bytes ->
          {:ok, bin, native_meta(bin, :native, nil)}

        distance >= @native_distance_max ->
          {:ok, bin, native_meta(bin, :best_effort, :max_bytes)}

        true ->
          native_descend(
            image,
            min(@native_distance_max, distance * 1.5 + 0.5),
            effort,
            max_bytes
          )
      end
    end
  end

  defp native_meta(bin, outcome, factor) do
    %{
      # 0 = native distance encode, no Q chosen
      quality: 0,
      bytes: byte_size(bin),
      iterations: 0,
      outcome: outcome,
      score: nil,
      confirm_passes: 0,
      scorer: :full,
      tiles_scored: nil,
      limiting_factor: factor
    }
  end

  defp native_start_meta(nqs, max_bytes) do
    %{
      objective: :butteraugli,
      min_quality: nqs.min_quality,
      max_quality: nqs.max_quality,
      target: nqs.target,
      max_bytes: max_bytes
    }
  end

  defp native_stop_meta({:ok, _binary, meta}) do
    %{
      result: :ok,
      objective: :butteraugli,
      chosen_quality: meta.quality,
      chosen_bytes: meta.bytes,
      iterations: meta.iterations,
      outcome: meta.outcome,
      final_score: meta.score,
      scorer: meta.scorer,
      tiles_scored: meta.tiles_scored,
      confirm_passes: meta.confirm_passes,
      limiting_factor: meta.limiting_factor
    }
  end

  defp native_stop_meta({:error, reason}) do
    %{result: :processing_error, objective: :butteraugli, error: reason}
  end
end
