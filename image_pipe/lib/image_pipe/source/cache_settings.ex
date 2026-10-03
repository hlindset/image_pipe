defmodule ImagePipe.Source.CacheSettings do
  @moduledoc """
  Cache settings shared by source adapters.

  Adapters append `schema/0` to their option schemas, which accepts:

    * `:stable` - `:auto` (default) or `:immutable`. `:immutable` promises that a
      source identifier's bytes never change.
    * `:cache_policy` - an `ImagePipe.Source.CachePolicy` keyword list (default `[]`).
    * `:internal_cache` - `:auto` (default), `:enabled`, or `:disabled`.
    * `:http_cache` - `:inherit` (default) or one of the mount's `:http_cache`
      values (`:validators`, `:auto`, `:public`, `:private`), which then
      replaces the mount's value for this source.

  After validating, `validate/1` rejects a TTL or stale window on an immutable
  source. `fields/2` then turns the validated options into the cache fields of
  `ImagePipe.Source.Resolved`.
  """

  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.CacheSemantics

  @schema [
    stable: [type: {:in, [:auto, :immutable]}, default: :auto],
    cache_policy: [type: {:custom, CachePolicy, :validate, []}, default: []],
    internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
    http_cache: [
      type: {:in, [:inherit, :validators, :auto, :public, :private]},
      default: :inherit
    ]
  ]

  @doc "NimbleOptions schema entries for the shared cache settings."
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc """
  Rejects a TTL or stale-while-revalidate window on an immutable source, which
  has no freshness deadline. Returns the options unchanged when valid.
  """
  @spec validate(keyword()) :: {:ok, keyword()} | {:error, {:invalid_source_config, String.t()}}
  defdelegate validate(opts), to: CachePolicy, as: :validate_source

  @doc "Whether the options mark the source as immutable."
  @spec immutable?(keyword()) :: boolean()
  def immutable?(opts), do: Keyword.fetch!(opts, :stable) == :immutable

  @doc """
  Returns the `:internal_cache`, `:http_cache`, and `:cache_semantics` fields
  of `ImagePipe.Source.Resolved`.

  Takes the validated options and:

    * `:stable?` - whether this source's bytes can't change, either because
      the options trust it or because the source itself pins them.
    * `:seed` - the byte-identity seed used when the source is stable. It must
      not contain secrets.
    * `:copy?` - whether to keep a local copy of the original in the input
      pool. Remote adapters pass `true`.

  A source that isn't stable is identified by its content. `internal_cache:
  :auto` enables internal caching.
  """
  @spec fields(keyword(), keyword()) :: keyword()
  def fields(opts, source) do
    stable? = Keyword.fetch!(source, :stable?)

    byte_identity =
      if stable?, do: {:strong, Keyword.fetch!(source, :seed)}, else: :content

    [
      internal_cache: internal_cache(opts),
      http_cache: Keyword.fetch!(opts, :http_cache),
      cache_semantics: %CacheSemantics{
        byte_identity: byte_identity,
        stable?: stable?,
        policy: Keyword.fetch!(opts, :cache_policy),
        copy?: Keyword.fetch!(source, :copy?)
      }
    ]
  end

  defp internal_cache(opts) do
    case Keyword.fetch!(opts, :internal_cache) do
      :auto -> :enabled
      mode -> mode
    end
  end
end
