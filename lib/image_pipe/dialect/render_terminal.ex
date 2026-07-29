defmodule ImagePipe.Dialect.RenderTerminal do
  @moduledoc """
  A non-image terminal, values only. Two deliveries, selected by `cache`:

    * `:complete_body` — the shared complete-body lifecycle: a
      `{:complete_body, content_type}` cache entry, `If-None-Match: *` honored
      on a hit, fail-open write on a miss.
    * `:none` — `ImagePipe.Response.Sender`'s `{:rendered, …}` delivery: the
      content type is negotiated against the CURRENT request's `Accept` over
      `offers`, `Vary: Accept` is stamped, and the internal cache is neither
      read nor written.

  Presentation is never stored: `offers`, the negotiated type, and `charset`
  come from the current terminal on both hit and miss; a cache entry keeps a
  bare canonical content type.

  `charset` selects how the content type is stamped on the `:complete_body`
  delivery. `nil` sends it verbatim; `:default` lets
  `Plug.Conn.put_resp_content_type/2` append the endpoint's default charset
  parameter. It does not apply to `:none`, whose content type is stamped by
  `ImagePipe.Response.Json`.

  `offers` is `[{content_type, [accept_token]}]` — the first entry whose tokens
  appear in the request's `Accept` wins; `[]` means no negotiation. It is
  meaningful only with `cache: :none`.
  """

  alias ImagePipe.Source

  @enforce_keys [:fun]
  defstruct [:fun, charset: nil, cache: :complete_body, offers: []]

  @type render_fun ::
          (Source.Resolved.t(), keyword() ->
             {:ok, content_type :: String.t(), iodata()} | {:error, term()})

  @type offer :: {content_type :: String.t(), accept_tokens :: [String.t()]}

  @type t :: %__MODULE__{
          fun: render_fun(),
          charset: :default | nil,
          cache: :complete_body | :none,
          offers: [offer()]
        }
end
