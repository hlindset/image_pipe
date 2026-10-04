defmodule ImagePipe.Plan.Output.QualitySearch do
  # A request's auto-quality search: a SSIMULACRA2 target from the request or
  # the host configuration, and the result size above which the search is
  # skipped. `resolve/2` returns `:none` when auto-quality is off.
  @moduledoc false

  @enforce_keys [:target, :max_resolution]
  defstruct @enforce_keys

  @type t :: %__MODULE__{target: float(), max_resolution: non_neg_integer()}

  @doc """
  Resolve the request's `autoquality` value over the host configuration.

  `nil` (unset) follows the host's `autoquality` toggle, `false` turns the
  search off, `true` uses the host's `autoquality_target`, and a number is the
  target itself.
  """
  @spec resolve(nil | boolean() | float(), keyword()) :: :none | t()
  def resolve(nil, config), do: resolve(Keyword.fetch!(config, :autoquality), config)
  def resolve(false, _config), do: :none
  def resolve(true, config), do: resolve(Keyword.fetch!(config, :autoquality_target), config)

  def resolve(target, config) when is_number(target) do
    %__MODULE__{
      target: target * 1.0,
      max_resolution: Keyword.fetch!(config, :autoquality_max_resolution)
    }
  end
end
