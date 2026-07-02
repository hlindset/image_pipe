defmodule ImagePipe.Plan.Operation.Directive do
  @moduledoc """
  A pipeline entry addressed to the plan's carried resolver strategy
  (spec §4.4; #438) — the strategy analogue of the Renderer's
  `{:custom, module, params}`. The `payload` is a parser-produced plain
  canonical term (a parser contract, asserted in parser tests, not validated
  downstream); key data hashes it generically. The neutral resolver has no
  `Directive` clause: a directive reaching a strategy that doesn't own it is
  impossible internal misuse and crashes.
  """

  @enforce_keys [:name, :payload]
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: atom(), payload: term()}
end
