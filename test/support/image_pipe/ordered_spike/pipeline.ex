defmodule ImagePipe.Test.OrderedSpike.Pipeline do
  @moduledoc """
  Ordered-planning spike (probe subset, dialect-owned pipelines #454): a
  synthetic TwicPics-like interpreter that evaluates a command list
  left-to-right, computing each executable op against the CURRENT MEASURED
  dims, running it, re-measuring, and continuing.

  **What this module does NOT use.** No `ImagePipe.Plan.Operation` semantic
  structs, no `ImagePipe.Transform.NeutralResolver`, no
  `{ops, continuation}` vocabulary, no injected strategy dispatch. Every
  command is compiled straight to a concrete `ImagePipe.Transform.Operation.*`
  executable struct using plain Elixir arithmetic against a live
  `Image.width/height` read — the interpreter is a single `Enum.reduce_while`
  loop (`run/3`). This is the probe's central claim under test: an ordered
  dialect does not need a generic callback seam to replace an injected
  strategy framework.

  **Command grammar (probe subset):**

    * `{:resize_w, pixels}` / `{:resize_h, pixels}` — an absolute,
      aspect-preserving resize (`mode: :fit`) fixing one axis to an exact
      pixel count; the other axis is `:auto` (aspect-derived from whatever
      the CURRENT image happens to be, at execute time).
    * `{:crop_rel, fx, fy}` — a centered crop taking `fx`/`fy` fractions
      (each in `(0, 1]`) of the CURRENT measured width/height.
    * `:trim` — an auto-background uniform-border trim (the ordered
      dialect's "unknown until measured" case: its output extent cannot be
      known without decoding pixels).

  **Deferred orientation.** `run/3` flushes any non-identity
  `state.pending_orientation` EAGERLY, before the first command, via an
  explicit `%ImagePipe.Transform.Operation.Flush{}` — unlike the native
  dialect (`ImagePipe.Dialect.Native.Pipeline`), which carries
  `pending_orientation` through `SourceShape` and flushes once at the very
  end. This is a deliberate probe simplification: the interpreter measures
  the LIVE image at every step, so the live frame must already be the
  DISPLAY frame from the start, or `{:resize_w, _}`/`{:crop_rel, _, _}`
  would silently resolve against the wrong (storage) axes for a quarter-turn
  source. The cost is the streaming fast path deferred orientation buys
  core (a materializing quarter-turn source pays its `copy_memory` up
  front instead of at the pipeline's tail) — noted in the Task 21 report,
  not fixed here.

  **`state.source_dimensions`/`state.decode_shrink` are cleared at the
  start of `run/3`.** These fields carry core's "residual resize sizes
  against the *exact original* extent" contract
  (`ImagePipe.Transform.State.effective_source_dims/1`) — a single
  resize-after-decode assumption that does not hold here: this interpreter
  may run a resize AFTER an earlier crop_rel in the SAME command list, and
  `effective_source_dims/1` would ignore that crop entirely (reading the
  pristine header dims off `source_dimensions` instead of the crop's
  live output) if left set. Clearing them makes every op's
  `effective_source_dims/1` read fall through to the live-image-dims
  branch, matching this interpreter's "always resolve against what's
  actually on state.image right now" contract.

  ## `preflight/2` — the decode-bound answer

  Walks the SAME command list PURELY over header dims (no pixel I/O),
  producing a conservative MINIMUM safe loaded extent (equivalently a
  MAXIMUM safe shrink factor) for `ImagePipe.Transform.DecodePlanner`'s
  `required_extent` floor. See the moduledoc on `preflight/2` for the
  propagation rules and their derivation.
  """

  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  @default_trim_threshold 10.0

  @type dims :: {pos_integer(), pos_integer()}
  @type command ::
          {:resize_w, pos_integer()}
          | {:resize_h, pos_integer()}
          | {:crop_rel, float(), float()}
          | :trim

  @doc """
  Builds the `DecodePlanner.Request` for a command list: the ordered
  dialect's own decode-preflight bracket, mirroring
  `ImagePipe.Dialect.Native.Pipeline.decode_request/2`'s role for the
  declarative dialect. Uses ONLY `required_extent` — every other
  `DecodePlanner.Request` field (`resize_target`, `crop_extent`, `trim?`,
  `terminal_reduction`) stays at its default, because none of them can
  express "a floor on the loaded extent that isn't itself an output box
  target" (see `preflight/2`).

  Uses `geometry.display_dimensions`, not `storage_dimensions`: this
  interpreter's commands (and therefore `preflight/2`'s bound) are already
  expressed against the DISPLAY frame (`run/3` flushes any pending
  orientation before the first command runs), and `DecodePlanner` compares
  `required_extent` directly against its own display-oriented
  `shrink_w`/`shrink_h` (storage dims swapped when a quarter-turn source is
  auto-rotated) — so `required_extent` must already be in that same frame.
  """
  @spec decode_request([command()], SourceGeometry.t()) :: DecodePlanner.Request.t()
  def decode_request(commands, %SourceGeometry{display_dimensions: dims})
      when is_list(commands) do
    required =
      case preflight(commands, dims) do
        :no_shrink -> dims
        %{minimum_loaded_width: w, minimum_loaded_height: h} -> {w, h}
      end

    %DecodePlanner.Request{required_extent: required}
  end

  @doc """
  Conservative decode-time bound for a command list, computed purely over
  `header_dims` (no pixels opened).

  Returns `%{minimum_loaded_width: pos_integer(), minimum_loaded_height:
  pos_integer()}` — the least a decode may shrink to on each axis and still
  guarantee the SAME final display geometry as a full-resolution decode — or
  `:no_shrink` when no such bound exists.

  ## Propagation rules

  The command list is walked BACKWARD (from the last command toward the
  first), carrying a per-axis requirement that starts `:unbounded`:

    * An ABSOLUTE op (`:resize_w`/`:resize_h`) RESETS the requirement: its
      own governing axis becomes a concrete floor (its pixel target); the
      OTHER axis becomes `:derived` — freed of any prior requirement,
      concrete or not. This is sound, not just convenient: shrink-on-load
      applies a single UNIFORM scalar to both axes (`DecodePlanner`), so
      once this op's own floor is met its governing axis lands on EXACTLY
      its target regardless of shrink, which makes its `:auto` axis exactly
      `target * (header_h / header_w)` (or the transposed form) — the same
      formula a full-resolution decode uses, because header aspect ratio is
      itself shrink-invariant. Everything the OTHER axis owed to commands
      further downstream is therefore automatically satisfied; nothing
      further back needs to protect it.
    * A RELATIVE op (`:crop_rel`) PROPAGATES the requirement per axis,
      scaled up by the reciprocal of its fraction (`req / fx`, `req / fy`):
      a crop taking a `fx` fraction of its input needs `req / fx` pixels of
      input to still deliver `req` pixels of output. `:unbounded` and
      `:derived` pass through unchanged (nothing concrete to scale).
    * `:trim` COLLAPSES the WHOLE requirement to `:no_shrink`, regardless of
      where it sits in the list. Unlike `:resize_w`/`:resize_h`,
      `:trim`'s output extent is CONTENT-dependent (`find_trim` locates a
      border by comparing pixel values), so it is not just "unknown until
      measured" in the geometric sense the reset rule above relies on — a
      shrunk decode can genuinely resample DIFFERENT pixel values than a
      full decode, which can shift the detected trim box even when the
      pixel dimensions feeding it are identical. There is no
      geometry-only argument (of the kind that justifies the absolute-op
      reset) that bounds this, so the ONLY safe answer is "decode does not
      shrink at all" — and since there is a single decode for the whole
      command list, this is checked up front rather than mid-walk: `:trim`
      anywhere in the list short-circuits straight to `:no_shrink` before
      the backward walk even starts.

  At the end of the walk (the position immediately before the first
  command, i.e. the decode boundary), an axis still `:unbounded` means no
  absolute op EVER anchored it — a purely relative chain has final
  ABSOLUTE dims proportional to header size, which shrink changes, so this
  also collapses the WHOLE answer to `:no_shrink`. A `:derived` axis
  resolves to `1` (a floor of `1` never binds `DecodePlanner`'s
  `ratio_from_targets/4` `min/2`, which is exactly the "don't add a
  constraint" the `:derived` state means). A concrete floor is rounded up
  (never down — the conservative direction) and clamped to `header_dims`
  on that axis (never demand more than the source has).

  ## A real (not just theoretical) rounding limitation — and why it COMPOUNDS

  The soundness argument above is exact in real-number arithmetic, but a
  decoded image's dims are always integers, and rounding sits between a
  bound and the pixels it protects: the decoder's own load-time `scale`/
  `shrink` option is ONE uniform float, rounded to whole pixels
  INDEPENDENTLY per axis. `test/image_pipe/shrink_on_load_property_test.exs`
  already documents a ±1px version of this for CORE's single-resize
  shrink-on-load path ("the contract is NOT 'output equals the
  full-decode result'... even the full-decode path can land ±1px off").

  This interpreter's version is worse, because it compounds: core resolves
  every operation's geometry against a SINGLE original extent, computed
  once, up front. This interpreter instead measures the LIVE (already
  decode-rounded) image at every step (`run/3`'s whole design — "compute
  against the CURRENT measured dims"), so a `:crop_rel` after a shrunk
  decode rounds AGAIN from an input that is itself already off by the
  decoder's own rounding, and a SUBSEQUENT `:crop_rel` rounds again from
  that. Drift does not reset per command; it can accumulate. An offline
  calibration sweep (3000 random 1-4 command lists over the property
  test's own generator shape, see `test/image_pipe/ordered_spike_test.exs`
  and the Task 21 report) found max drift 2px, occurring in roughly 1 in
  1500 cases; the property test asserts a ±2px tolerance calibrated from
  that sweep, not a proven fixed constant — a deeper ordered pipeline could
  compound further.
  """
  @spec preflight([command()], dims()) ::
          %{minimum_loaded_width: pos_integer(), minimum_loaded_height: pos_integer()}
          | :no_shrink
  def preflight(commands, {header_w, header_h}) when is_list(commands) do
    if Enum.member?(commands, :trim) do
      :no_shrink
    else
      {req_w, req_h} =
        commands
        |> Enum.reverse()
        |> Enum.reduce({:unbounded, :unbounded}, &step_back/2)

      case {resolve_axis(req_w, header_w), resolve_axis(req_h, header_h)} do
        {:no_shrink, _axis} -> :no_shrink
        {_axis, :no_shrink} -> :no_shrink
        {w, h} -> %{minimum_loaded_width: w, minimum_loaded_height: h}
      end
    end
  end

  defp step_back({:resize_w, n}, {_w, h}), do: {n * 1.0, reset_other(h)}
  defp step_back({:resize_h, n}, {w, _h}), do: {reset_other(w), n * 1.0}
  defp step_back({:crop_rel, fx, fy}, {w, h}), do: {propagate(w, fx), propagate(h, fy)}

  # An absolute op resets its OWN axis (handled by the caller) and frees the
  # OTHER axis unconditionally — see the propagation-rules doc above.
  defp reset_other(_previous), do: :derived

  defp propagate(:unbounded, _factor), do: :unbounded
  defp propagate(:derived, _factor), do: :derived
  defp propagate(n, factor) when is_number(n) and is_number(factor), do: n / factor

  defp resolve_axis(:unbounded, _header_dim), do: :no_shrink
  defp resolve_axis(:derived, _header_dim), do: 1
  defp resolve_axis(n, header_dim) when is_number(n), do: n |> ceil() |> max(1) |> min(header_dim)

  @doc """
  Runs a command list left-to-right against a decoded `State`: per command,
  compute the executable op against the CURRENT measured dims →
  `Chain.execute/3` → measure → update state → next.

  Returns `{:ok, final_state, dims_after_each_command}` — the second
  element is the live `{width, height}` measured immediately after each
  command ran, in command order, letting a caller assert the interpreter's
  own step-by-step geometry without re-deriving it.

  `opts` accepts the same test-only overrides `Chain.execute/3` and
  `ImagePipe.Dialect.Native.Pipeline.run/4` accept: `:chain` (default
  `&Chain.execute/3`) and `:measure_dims` (default a live `Image.width/
  height` read). Real callers never set these; everything else in `opts`
  passes straight through to `Chain.execute/3` (telemetry, etc).
  """
  @spec run(State.t(), [command()], keyword()) ::
          {:ok, State.t(), [dims()]} | {:error, term()}
  def run(%State{} = state, commands, opts \\ []) when is_list(commands) do
    chain_fun = Keyword.get(opts, :chain, &Chain.execute/3)
    measure_fun = Keyword.get(opts, :measure_dims, &default_measure_dims/1)

    with {:ok, %State{} = state} <- flush_pending_orientation(state, chain_fun, opts) do
      state = %State{state | source_dimensions: nil, decode_shrink: nil}

      commands
      |> Enum.reduce_while({:ok, state, []}, fn command, {:ok, state, acc} ->
        run_command(command, state, acc, chain_fun, measure_fun, opts)
      end)
      |> finalize()
    end
  end

  defp flush_pending_orientation(%State{pending_orientation: nil} = state, _chain_fun, _opts),
    do: {:ok, state}

  defp flush_pending_orientation(%State{pending_orientation: po} = state, chain_fun, opts) do
    if PendingOrientation.identity?(po) do
      {:ok, %State{state | pending_orientation: nil}}
    else
      chain_fun.(state, [%Flush{}], opts)
    end
  end

  defp run_command(command, state, acc, chain_fun, measure_fun, opts) do
    dims = measure_fun.(state.image)
    op = build_op(command, dims)

    case chain_fun.(state, [op], opts) do
      {:ok, new_state} -> {:cont, {:ok, new_state, [measure_fun.(new_state.image) | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize({:ok, state, acc}), do: {:ok, state, Enum.reverse(acc)}
  defp finalize({:error, _reason} = error), do: error

  defp default_measure_dims(image), do: {Image.width(image), Image.height(image)}

  defp build_op({:resize_w, n}, _dims) when is_integer(n) and n > 0 do
    %Resize{mode: :fit, width: {:pixels, n}, height: :auto}
  end

  defp build_op({:resize_h, n}, _dims) when is_integer(n) and n > 0 do
    %Resize{mode: :fit, width: :auto, height: {:pixels, n}}
  end

  defp build_op({:crop_rel, fx, fy}, {w, h})
       when is_number(fx) and fx > 0 and fx <= 1 and is_number(fy) and fy > 0 and fy <= 1 do
    %Crop{
      width: {:pixels, max(1, round(w * fx))},
      height: {:pixels, max(1, round(h * fy))},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center}
    }
  end

  defp build_op(:trim, _dims) do
    %Trim{
      threshold: @default_trim_threshold,
      background: :auto,
      equal_hor: false,
      equal_ver: false
    }
  end
end
