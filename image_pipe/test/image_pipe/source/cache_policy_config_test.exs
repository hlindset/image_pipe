defmodule ImagePipe.Source.CachePolicyConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.HTTP

  test "mount policy is inherited per field and a source can override storage permission" do
    opts =
      ImagePipe.Plug.init(
        source_cache_policy: [storage: :deny, freshness: {:fallback, 60}],
        sources: [url: {HTTP, allowed_hosts: ["example.com"], cache_policy: [storage: :allow]}]
      )

    assert {:ok, source} = Source.resolve(url(), opts, Source.runtime_opts(opts))

    assert Map.new(source.cache_semantics.policy) == %{
             storage: :allow,
             freshness: {:fallback, 60}
           }

    assert source.cache_semantics.byte_identity == :none
    refute source.cache_semantics.stable?
  end

  test "denied storage disables the output cache even for a trusted source" do
    opts =
      ImagePipe.Plug.init(
        source_cache_policy: [storage: :deny],
        sources: [url: {HTTP, allowed_hosts: ["example.com"], stable: :trusted}]
      )

    assert {:ok, source} = Source.resolve(url(), opts, Source.runtime_opts(opts))
    assert source.internal_cache == :disabled
    assert source.cache_semantics.stable?
  end

  test "invalid policy is rejected during mount initialization" do
    for policy <- [[freshness: {:force, -1}], [unknown: true], [stale_while_revalidate: 10]] do
      assert_raise ArgumentError, fn -> ImagePipe.Plug.init(source_cache_policy: policy) end

      assert_raise ArgumentError, fn ->
        ImagePipe.Plug.init(
          sources: [url: {HTTP, allowed_hosts: ["example.com"], cache_policy: policy}]
        )
      end
    end
  end

  test "trusted immutability rejects an explicit finite source lifetime" do
    assert_raise ArgumentError, fn ->
      ImagePipe.Plug.init(
        sources: [
          url:
            {HTTP,
             allowed_hosts: ["example.com"],
             stable: :trusted,
             cache_policy: [freshness: {:force, 60}]}
        ]
      )
    end
  end

  test "trusted sources inherit storage policy but supersede the mount freshness default" do
    opts =
      ImagePipe.Plug.init(
        source_cache_policy: [storage: :allow, freshness: {:fallback, 60}],
        sources: [url: {HTTP, allowed_hosts: ["example.com"], stable: :trusted}]
      )

    assert {:ok, source} = Source.resolve(url(), opts, Source.runtime_opts(opts))

    state =
      Source.CacheState.from_headers(
        %{},
        source.cache_semantics.policy,
        source.cache_semantics.stable?,
        {100, 100}
      )

    assert Source.CacheState.status(state, 1_000_000) == :fresh
  end

  test "S3 bucket policy overrides fields and can assert immutability over defaults" do
    opts =
      ImagePipe.Plug.init(
        sources: [
          s3:
            {Source.S3,
             default: [
               region: "us-east-1",
               endpoint: "https://s3.example.com",
               credentials: {:static, access_key_id: "A", secret_access_key: "S"},
               cache_policy: [storage: :deny, freshness: {:fallback, 60}]
             ],
             buckets: %{"images" => [stable: :trusted, cache_policy: [storage: :allow]]}}
        ]
      )

    intent = %ImagePipe.Plan.Source.Object{
      adapter: :s3,
      scope: "images",
      key: "cat.jpg",
      revision: nil
    }

    assert {:ok, source} = Source.resolve(intent, opts, Source.runtime_opts(opts))

    assert Map.new(source.cache_semantics.policy) == %{
             storage: :allow,
             freshness: {:fallback, 60}
           }

    assert source.cache_semantics.stable?
  end

  defp url do
    %URL{scheme: :https, host: "example.com", port: nil, path: ["cat.jpg"], query: nil}
  end
end
