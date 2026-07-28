defmodule ImagePipe.Dialect.Resolved do
  @moduledoc """
  The product of `c:ImagePipe.Dialect.prepare/3` — values, not callbacks.

  `negotiation` is a deferred, coupled result: identity material cannot
  exist without a successful negotiation (every identity builder consumes
  the struct), so the pair succeeds or fails together. It may be supplied
  directly as the result tuple, or as a zero-arity thunk returning that
  tuple — the thunk form lets a dialect defer negotiation until runtime
  geometry (unavailable at `prepare/3` time) is known. The runner resolves
  it AFTER `ImagePipe.Source.resolve/3`, preserving the dialects'
  source-before-negotiation error precedence.

  The spec's `http_cache: :generated | :dialect_owned` field is deliberately
  ABSENT in Phase A: the promoted header-policy module it dispatches to is
  Phase C work, and a representable-but-inert value would advertise
  unsupported semantics. Phase C adds the field together with the policy
  module; until then every dialect gets today's dialect-owned behavior.
  """

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Plan.Response
  alias ImagePipe.Representation.IdentityMaterial

  @enforce_keys [
    :request,
    :source,
    :negotiation,
    :response_meta,
    :operations,
    :auto_rotate?,
    :debug?,
    :terminal
  ]
  defstruct @enforce_keys

  @type negotiation_result ::
          {:ok, Negotiation.t(), IdentityMaterial.t()} | {:error, term()}

  @type negotiation :: negotiation_result() | (-> negotiation_result())

  @type t :: %__MODULE__{
          request: term(),
          source: struct(),
          negotiation: negotiation(),
          response_meta: Response.t(),
          operations: [atom()],
          auto_rotate?: boolean(),
          debug?: boolean(),
          terminal: :image | {:render, RenderTerminal.t()}
        }
end
