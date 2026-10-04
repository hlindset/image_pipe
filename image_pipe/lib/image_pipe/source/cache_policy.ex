defmodule ImagePipe.Source.CachePolicy do
  @type t :: keyword()

  @schema NimbleOptions.new!(
            storage: [
              type: {:in, [:origin, :allow, :deny]},
              type_doc: "`:origin`, `:allow`, or `:deny`",
              doc: """
              Whether originals and processed images may be stored. `:origin`, the \
              default, stores unless the origin sends `no-store` or `private`. \
              `:allow` stores despite them, and `:deny` never stores. `Vary: *` from \
              the origin prevents storage in every mode.
              """
            ],
            freshness: [
              type:
                {:or,
                 [
                   {:in, [:origin]},
                   {:tuple, [{:in, [:fallback, :force]}, :non_neg_integer]}
                 ]},
              type_doc: "`:origin`, `{:fallback, seconds}`, or `{:force, seconds}`",
              doc: """
              How long a stored copy stays fresh. `:origin`, the default, uses the \
              origin's lifetime and revalidates on every request when there is none. \
              `{:fallback, seconds}` applies only when the origin sends no lifetime. \
              `{:force, seconds}` replaces the origin's lifetime, including \
              `no-cache`. Neither makes a \
              response storable that `:storage` doesn't allow.
              """
            ],
            stale_while_revalidate: [
              type:
                {:or,
                 [
                   {:in, [:origin, :disabled]},
                   {:tuple, [{:in, [:force]}, :non_neg_integer]}
                 ]},
              type_doc: "`:origin`, `:disabled`, or `{:force, seconds}`",
              doc: """
              How long an expired copy may still be served while it is refreshed. \
              `:origin`, the default, uses the origin's `stale-while-revalidate`, \
              which an origin `no-cache`, `must-revalidate`, `proxy-revalidate`, or \
              `s-maxage` turns off. `:disabled` serves no expired copies. \
              `{:force, seconds}` sets the window, whatever the origin sends.
              """
            ]
          )

  @moduledoc """
  Cache storage and freshness policy for originals and processed images.

      ImagePipe.config(
        source_cache_policy: [storage: :origin, freshness: {:fallback, 300}],
        sources: [...]
      )

  `:source_cache_policy` in `ImagePipe.config/1` sets the policy for every
  source. A source's own `:cache_policy` replaces it field by field. All
  durations are in seconds. See
  [source cache settings](cache.md#source-cache-settings) and
  [caching and freshness](caching-and-freshness.md).

  An [immutable source](caching-and-freshness.md#immutable-sources) has no
  freshness deadline, even when it inherits a finite `:freshness`, but still
  needs `:storage` to allow storing. Its own `:cache_policy` can't set a
  `:freshness` duration or a `:stale_while_revalidate` window.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @doc false
  def options_schema, do: @schema.schema

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

    case opts[:stable] == :immutable and (finite_freshness? or stale_override?) do
      true ->
        {:error, {:invalid_source_config, "immutable sources cannot specify a TTL or SWR window"}}

      false ->
        {:ok, opts}
    end
  end

  @doc "Merges validated policies field by field, with source settings taking precedence."
  @spec merge(t(), t()) :: t()
  def merge(defaults, overrides), do: Keyword.merge(defaults, overrides)
end
