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

  `http_cache` selects whether the runner applies the core generated
  cache-header policy (`ImagePipe.Response.CachePolicy`) between building the
  representation and the conditional gate:

    * `:generated` — the policy runs. It generates `Cache-Control` and emits
      the representation's `ETag` subject to the host-override and
      byte-identity suppression rules, and its suppression can veto the 304.
      It also owns the `[:http_cache, :prepare]`,
      `[:http_cache, :conditional, :match]`, and
      `[:http_cache, :fallback, :no_store]` events. Requires an
      `http_cache: [mode: :enabled]` config to generate anything at all.
    * `:dialect_owned` — the policy is skipped; identity headers come straight
      from the representation and none of those three events fire.
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
    :http_cache,
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
          http_cache: :generated | :dialect_owned,
          terminal: :image | {:render, RenderTerminal.t()}
        }
end
