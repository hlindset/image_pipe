defmodule ImagePipe.Source.CacheSettings do
  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.CacheSemantics

  @schema [
    stable: [
      type: {:in, [:auto, :immutable]},
      type_doc: "`:auto` or `:immutable`",
      default: :auto,
      doc: """
      `:immutable` marks an immutable source: an identifier always names the \
      same bytes, so its originals and processed images never expire and are \
      never revalidated. With `:auto`, each original is identified by its \
      content. See [immutable sources](caching-and-freshness.md#immutable-sources).
      """
    ],
    cache_policy: [
      type: {:custom, CachePolicy, :validate, []},
      type_doc: "`t:keyword/0`",
      default: [],
      doc: """
      Cache policy for this source, with the fields of \
      `ImagePipe.Source.CachePolicy`. Each field it sets replaces that field \
      of the `:source_cache_policy` of `ImagePipe.config/1`. A source with \
      `stable: :immutable` can't set a `:freshness` duration or a \
      `:stale_while_revalidate` window.
      """
    ],
    internal_cache: [
      type: {:in, [:auto, :enabled, :disabled]},
      type_doc: "`:auto`, `:enabled`, or `:disabled`",
      default: :auto,
      doc: """
      `:disabled` keeps this source's originals and processed images out of \
      the caches. `:auto` and `:enabled` cache what the source's storage \
      policy allows.
      """
    ],
    http_cache: [
      type: {:in, [:inherit, :validators, :auto, :public, :private]},
      type_doc: "`:inherit`, `:validators`, `:auto`, `:public`, or `:private`",
      default: :inherit,
      doc: """
      HTTP cache headers for responses from this source. `:inherit` uses the \
      mount's `:http_cache` (see `ImagePipe.Plug`), and any other value \
      replaces it. See [per-source modes](cdn-http-cache.md#per-source-modes).
      """
    ]
  ]

  @moduledoc """
  Cache settings shared by source adapters.

  The built-in adapters accept these options, and a custom adapter can append
  `schema/0` to its own option schema to accept them too:

      @schema NimbleOptions.new!([bucket: [type: :string, required: true]] ++ CacheSettings.schema())

  After validating, `validate/1` rejects a lifetime or stale window on an
  immutable source. `fields/2` then turns the validated options into the
  cache fields of `ImagePipe.Source.Resolved`. Their effect is explained in
  [Caching and freshness](caching-and-freshness.md).

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

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
