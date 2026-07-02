defmodule ImagePipe.Transform.SourceShape do
  @moduledoc false
  # Pure geometry value threaded by the resolve driver (spec §4.3). Subsumes
  # State.source_dimensions/decode_shrink/pending_orientation. Never in telemetry.
  alias ImagePipe.Transform.PendingOrientation

  @enforce_keys [:width, :height, :frame]
  defstruct [:width, :height, :frame, pending_orientation: nil, decode_shrink: nil]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          frame: :storage | :display,
          pending_orientation: PendingOrientation.t() | nil,
          decode_shrink: %{w: float(), h: float()} | nil
        }

  @spec seed(%{
          width: pos_integer(),
          height: pos_integer(),
          pending_orientation: PendingOrientation.t() | nil,
          decode_shrink: %{w: float(), h: float()} | nil
        }) :: t()
  def seed(%{width: w, height: h, pending_orientation: po, decode_shrink: shrink})
      when is_integer(w) and w > 0 and is_integer(h) and h > 0,
      do: %__MODULE__{
        width: w,
        height: h,
        frame: :storage,
        pending_orientation: po,
        decode_shrink: shrink
      }

  @spec quarter_turn?(t()) :: boolean()
  def quarter_turn?(%__MODULE__{pending_orientation: nil}), do: false

  def quarter_turn?(%__MODULE__{pending_orientation: po}),
    do: PendingOrientation.quarter_turn?(po)

  # The live (decoded) image dims implied by the shape: the effective source
  # dims divided by the realized shrink-on-load factor (exact — the factor is
  # original ÷ decoded, so the division round-trips the decoded extent).
  # Exact ONLY while the shape is frame-coherent: width/height and decode_shrink
  # must describe the same frame, i.e. no advance may change the dims without
  # clearing or compensating an outstanding shrink (the Task-0 fixtures pin the
  # one reachable violation, canvas-under-shrink).
  @spec live_dims(t()) :: {pos_integer(), pos_integer()}
  def live_dims(%__MODULE__{width: w, height: h, decode_shrink: nil}), do: {w, h}

  def live_dims(%__MODULE__{width: w, height: h, decode_shrink: %{w: sw, h: sh}}),
    do: {max(1, round(w / sw)), max(1, round(h / sh))}
end
