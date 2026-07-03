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
end
