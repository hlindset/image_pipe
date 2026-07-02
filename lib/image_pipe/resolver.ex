defmodule ImagePipe.Resolver do
  @moduledoc """
  Neutral behaviour + dispatch facade for geometry resolution (spec §4.2/§5.1).
  A plan carries a strategy `spec` (`{module, strategy_state}`); the driver calls
  `resolve/3`; the dynamic call to the carried module is quarantined here (mirrors
  `ImagePipe.Renderer`). The continuation is the only `strategy_state` channel —
  it carries the strategy's next state forward (see `ImagePipe.Transform.
  ResolveDriver.advance/4`). The facade passes shape opaquely — no runtime
  reference to `SourceShape` — so this boundary stays `deps: [ImagePipe.Plan]`.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type spec :: {module(), strategy_state()}
  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), strategy_state()})}

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
