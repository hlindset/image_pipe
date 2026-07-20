defmodule ImagePipe.Dialect.Resolved do
  @moduledoc """
  The product of `c:ImagePipe.Dialect.prepare/3` — values, not callbacks.

  `negotiation` is a deferred, coupled result: identity material cannot
  exist without a successful negotiation (every identity builder consumes
  the struct), so the pair succeeds or fails together. The runner unwraps
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

  @type t :: %__MODULE__{
          request: term(),
          source: struct(),
          negotiation: negotiation_result(),
          response_meta: Response.t(),
          operations: [atom()],
          auto_rotate?: boolean(),
          debug?: boolean(),
          terminal: :image | {:render, RenderTerminal.t()}
        }
end
