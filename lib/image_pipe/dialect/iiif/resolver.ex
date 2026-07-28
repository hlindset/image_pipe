defmodule ImagePipe.Dialect.IIIF.Resolver do
  @moduledoc """
  Host extension point mapping an opaque IIIF identifier to a product-neutral
  `ImagePipe.Plan.Source`. Configured via the mount's `resolver: {Module, opts}`.
  """

  @callback resolve(identifier :: String.t(), opts :: keyword()) ::
              {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}

  @doc """
  Validates a host-supplied `{Module, opts}` resolver pair.

  The module is host code arriving at the mount boundary, so its shape is
  checked here rather than trusted: an unloadable module or one missing
  `resolve/2` would otherwise surface as an `UndefinedFunctionError` on the
  first request instead of at boot.
  """
  @spec validate(term()) :: {:ok, {module(), keyword()}} | {:error, String.t()}
  def validate({module, opts} = resolver) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :resolve, 2),
      do: {:ok, resolver},
      else: {:error, "resolver module must export resolve/2"}
  end

  def validate(_resolver), do: {:error, "resolver must be {Module, opts}"}
end
