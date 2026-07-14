defmodule ImagePipe.Output.Terminal.Blurhash do
  @moduledoc """
  Shared blurhash terminal computation (`ImagePipe.Output.Terminal.Blurhash`).

  Identity-only in this task: `identity/0` contributes the terminal
  computation's identity tuple to `representation` material, so a change in
  the terminal's behavior reaches the cache key and ETag. `compute/1` (the
  actual pixel computation, 4x3 components against a fixed sRGB/tone-mapped
  pixel space) lands with the dialect's blurhash terminal.
  """

  @doc """
  The terminal computation's identity: fixed 4x3 blurhash components. Enters
  `Representation.IdentityMaterial.representation` so a future component
  change (or any other behavior change) rides identity via this tuple, not
  luck.
  """
  @spec identity() :: {:blurhash, 1}
  def identity, do: {:blurhash, 1}
end
