defmodule ImagePipe.Source.CachePolicy do
  @moduledoc """
  Host policy shared by source and derived-response caches.

  `:storage` is `:origin` (default), `:allow`, or `:deny`. Freshness never
  overrides storage permission. `:freshness` is `:origin`, `{:fallback, seconds}`,
  or `{:force, seconds}`. Fallback applies only when the origin supplies no
  freshness; force explicitly replaces it. `:stale_while_revalidate` is
  `:origin`, `:disabled`, or `{:force, seconds}`.

  Omitted fields inherit the mount policy. A trusted immutable source has no
  freshness deadline, including when it inherits a finite mount default, but
  still needs permission to store. Explicit source TTL/SWR overrides conflict
  with `stable: :trusted` and are rejected. All durations are
  seconds. These are host settings, never request URL options.
  """

  @type t :: keyword()

  @schema NimbleOptions.new!(
            storage: [type: {:in, [:origin, :allow, :deny]}],
            freshness: [
              type:
                {:or,
                 [
                   {:in, [:origin]},
                   {:tuple, [{:in, [:fallback, :force]}, :non_neg_integer]}
                 ]}
            ],
            stale_while_revalidate: [
              type:
                {:or,
                 [
                   {:in, [:origin, :disabled]},
                   {:tuple, [{:in, [:force]}, :non_neg_integer]}
                 ]}
            ]
          )

  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, policy} -> {:ok, policy}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def validate(_opts), do: {:error, "expected a keyword list"}

  @doc false
  def validate_source(opts) do
    policy = Keyword.fetch!(opts, :cache_policy)

    finite_freshness? = is_tuple(Keyword.get(policy, :freshness))
    stale_override? = is_tuple(Keyword.get(policy, :stale_while_revalidate))

    case opts[:stable] == :trusted and (finite_freshness? or stale_override?) do
      true ->
        {:error,
         {:invalid_source_config, "trusted immutable sources cannot specify a TTL or SWR window"}}

      false ->
        {:ok, opts}
    end
  end

  @doc "Merges validated policies field by field, with source settings taking precedence."
  @spec merge(t(), t()) :: t()
  def merge(defaults, overrides), do: Keyword.merge(defaults, overrides)
end
