defmodule ImagePipe.Resolver do
  @moduledoc """
  Neutral behaviour + dispatch facade for geometry resolution (spec §4.2/§5.1).
  A plan carries a strategy `spec` (`{module, strategy_state}`); the driver calls
  `resolve/3`; the dynamic call to the carried module is quarantined here (mirrors
  `ImagePipe.Renderer`). The continuation is the only `strategy_state` channel —
  it carries the strategy's next state forward, and (spec §4.4 Stage 3) may stage
  a multi-executable expansion: an `:acquire` `then_fn` can return a further
  `{ops, continuation}` stage, split at the realized-dims seam, which the driver
  executes and continues (see `ImagePipe.Transform.ResolveDriver.execute_stages/7`
  and `continue/6`). The facade passes shape opaquely — no runtime reference to
  `SourceShape` — so this boundary stays `deps: [ImagePipe.Plan]`.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type spec :: {module(), strategy_state()}

  @typedoc """
  What an `:acquire` `then_fn` returns: the final post-op `{shape,
  strategy_state}`, or a further `{ops, continuation}` stage — a
  multi-executable expansion split at the realized-dims seam (spec §4.4). The
  driver executes the stage's ops and continues; shape acquisition stays the
  driver's one seam, just allowed to fire more than once per plan op.
  """
  @type acquire_result ::
          {SourceShape.t(), strategy_state()}
          | {[struct()], continuation()}

  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:acquire, ({pos_integer(), pos_integer()} -> acquire_result())}

  @callback init() :: strategy_state()
  @callback resolve(SourceShape.t(), strategy_state(), struct()) ::
              {[struct()], continuation()}

  @doc """
  Behavioral version of this strategy's resolution algorithms. Enters
  `ImagePipe.Cache.Key.plan_material/2` (hence the ETag material): bump it when
  any resolution rule this strategy owns changes algorithm, so stale-but-
  differently-resolved bytes cannot be revalidated through a stable ETag
  (spec §7). Orthogonal to the key schema version.
  """
  @callback behavior_version() :: pos_integer()

  @spec resolve(spec(), shape :: term(), struct()) :: {[struct()], continuation()}
  def resolve({module, strategy_state}, shape, op) do
    module.resolve(shape, strategy_state, op)
  end

  @doc """
  Re-wrap a continuation produced by a stateless (nil-state) strategy so the
  caller's `strategy_state` survives the advance.

  The standard carried-state pattern delegates shared geometry to a stateless
  strategy (`ImagePipe.Transform.NeutralResolver`) and layers dialect decisions
  on top. The delegate threads `nil` into every continuation it builds, so a
  carried strategy that returns those continuations unmodified loses its state
  at the first `:advance`. `rewrap/2` substitutes the carry — through
  `:advance`, through `:acquire`, and recursively through every stage of a
  staged expansion.

  Matching the inner state to `nil` is deliberate: re-wrapping a continuation
  whose strategy carries its own state would silently discard it, so that
  misuse crashes instead.

  A strategy whose state must be *transformed* per emitted op (not carried
  unchanged) walks the emission itself; see
  `ImagePipe.Parser.TwicPics.PointFlow`.
  """
  @spec rewrap(continuation(), strategy_state()) :: continuation()
  def rewrap({:advance, shape, nil}, strategy_state), do: {:advance, shape, strategy_state}

  def rewrap({:acquire, then_fn}, strategy_state) do
    {:acquire,
     fn dims ->
       case then_fn.(dims) do
         {ops, continuation} when is_list(ops) -> {ops, rewrap(continuation, strategy_state)}
         {shape, nil} -> {shape, strategy_state}
       end
     end}
  end
end
