defmodule ImagePipe.Resolver do
  @moduledoc """
  Neutral behaviour + dispatch facade for geometry resolution (spec §4.2/§5.1).
  A plan carries a `strategy` (`{module, strategy_state}`); the driver calls
  `resolve/3` per plan op and `continue/5` per measure seam; the dynamic calls
  to the carried module are quarantined here (mirrors `ImagePipe.Renderer`).

  The continuation is plain data and the only `strategy_state` channel:
  `{:advance, shape, state}` when the strategy computed the post-op geometry
  purely, or `{:measure, tag, state}` when it cannot be known without looking
  at the realized image. The driver measures the live dims and calls
  `continue(tag, dims, shape, state)` on the strategy — `shape` being the
  pre-op shape the strategy's `resolve/3` saw for the current plan op — which
  returns the final `{shape, state}` or a further `{ops, continuation}` stage:
  a multi-executable expansion split at the realized-dims seam (spec §4.4
  Stage 3), which the driver executes and continues. Tags are strategy-private
  vocabulary; the driver never inspects them.

  The facade passes shape opaquely — no runtime reference to `SourceShape` —
  so this boundary stays `deps: [ImagePipe.Plan]`.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type strategy :: {module(), strategy_state()}

  @typedoc """
  A strategy-private continuation tag: names what happens after the measure
  (e.g. `ImagePipe.Transform.NeutralResolver`'s `{:resize_flush_tail, tail}`).
  Opaque to the driver.
  """
  @type tag :: term()

  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:measure, tag(), strategy_state()}

  @typedoc """
  What `continue/4` returns: the final post-op `{shape, strategy_state}`, or a
  further `{ops, continuation}` stage — a multi-executable expansion split at
  the realized-dims seam (spec §4.4). The driver executes the stage's ops and
  continues; shape measurement stays the driver's one seam, just allowed to
  fire more than once per plan op.
  """
  @type continue_result ::
          {SourceShape.t(), strategy_state()}
          | {[struct()], continuation()}

  @callback init() :: strategy_state()
  @callback resolve(SourceShape.t(), strategy_state(), struct()) ::
              {[struct()], continuation()}

  @doc """
  Continue a `{:measure, tag, strategy_state}` continuation once the realized
  dims are known. `shape` is the pre-op shape `resolve/3` saw for the current
  plan op; `strategy_state` is the state carried in the continuation.
  """
  @callback continue(tag(), {pos_integer(), pos_integer()}, SourceShape.t(), strategy_state()) ::
              continue_result()

  @doc """
  Behavioral version of this strategy's resolution algorithms. Enters
  `ImagePipe.Cache.Key.plan_material/2` (hence the ETag material): bump it when
  any resolution rule this strategy owns changes algorithm, so stale-but-
  differently-resolved bytes cannot be revalidated through a stable ETag
  (spec §7). Orthogonal to the key schema version.
  """
  @callback behavior_version() :: pos_integer()

  @spec resolve(strategy(), shape :: term(), struct()) :: {[struct()], continuation()}
  def resolve({module, strategy_state}, shape, op) do
    module.resolve(shape, strategy_state, op)
  end

  @spec continue(
          strategy(),
          tag(),
          {pos_integer(), pos_integer()},
          shape :: term(),
          strategy_state()
        ) :: continue_result()
  def continue({module, _resolve_state}, tag, dims, shape, strategy_state) do
    module.continue(tag, dims, shape, strategy_state)
  end

  @doc """
  Substitute the caller's `strategy_state` into a continuation produced by a
  stateless (nil-state) strategy so the carry survives the advance.

  The standard carried-state pattern delegates shared geometry to a stateless
  strategy (`ImagePipe.Transform.NeutralResolver`) and layers dialect decisions
  on top. The delegate threads `nil` into every continuation it builds, so a
  carried strategy that returns those continuations unmodified loses its state
  at the first `:advance`. A carried strategy's `continue/4` delegates the tag
  the same way and re-wraps any staged expansion's continuation it gets back.

  Matching the inner state to `nil` is deliberate: re-wrapping a continuation
  whose strategy carries its own state would silently discard it, so that
  misuse crashes instead.

  A strategy whose state must be *transformed* per emitted op (not carried
  unchanged) walks the emission itself; see
  `ImagePipe.Parser.TwicPics.PointFlow`.
  """
  @spec rewrap(continuation(), strategy_state()) :: continuation()
  def rewrap({:advance, shape, nil}, strategy_state), do: {:advance, shape, strategy_state}
  def rewrap({:measure, tag, nil}, strategy_state), do: {:measure, tag, strategy_state}
end
