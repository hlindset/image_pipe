defmodule ImagePipe.Output.JxlDistance do
  @moduledoc """
  libjxl's quality→distance mapping (`JxlEncoderDistanceFromQuality`), replicated
  so the native-JXL autoquality strategy can clamp a butteraugli-distance target
  into a Q-scale `[min_quality, max_quality]` bracket. Monotone non-increasing in
  quality. This duplicates a libjxl encode-internal; the duplication is pinned by
  a drift-guard test asserting `encode(Q=q) == encode(distance=from_quality(q))`
  against the installed libvips/libjxl (see `jxl_distance_test.exs`).

  Verified byte-identical against libvips 8.18.2 (libjxl) for Q ∈ {50, 70, 80, 90}.
  """

  @doc "Target butteraugli distance for an integer/float JXL quality `q`."
  @spec from_quality(number()) :: float()
  def from_quality(q) when q >= 100, do: 0.0
  def from_quality(q) when q >= 90, do: (100 - q) * 0.10
  def from_quality(q) when q >= 30, do: 0.1 + (100 - q) * 0.09
  def from_quality(q) when q > 0, do: 15.0 + (59.0 * q - 4350.0) * q / 9000.0
  def from_quality(_q), do: 15.0
end
