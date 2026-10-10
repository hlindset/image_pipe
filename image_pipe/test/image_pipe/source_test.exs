defmodule ImagePipe.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Path
  alias ImagePipe.Source.Path, as: SourcePath
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.URL
  alias ImagePipe.SourceTest.CustomAdapter
  alias ImagePipe.SourceTest.InvalidAdapter
  alias ImagePipe.SourceTest.InvalidConfigAdapter
  alias ImagePipe.SourceTest.InvalidIdentityAdapter
  alias ImagePipe.SourceTest.RaisingAdapter
  alias ImagePipe.SourceTest.StreamWithCleanup

  test "source validation rejects resolved values without cache semantics" do
    defmodule MissingSemanticsSource do
      @behaviour ImagePipe.Source

      def identifiers(_options),
        do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]

      def validate_options(opts), do: {:ok, opts}

      def resolve(%SourcePath{}, _opts, _runtime_opts) do
        {:ok,
         %Resolved{
           identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
           internal_cache: :disabled,
           http_cache: :inherit,
           cache_semantics: nil,
           fetch: [path: "/tmp/cat.jpg"]
         }}
      end

      def fetch(_resolved, _opts, _runtime_opts), do: raise("not used")
    end

    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: MissingSemanticsSource, match: :path, options: []]]
             )

    source = %SourcePath{segments: ["cat.jpg"]}

    assert {:error, {:source, :invalid_adapter_result}} = Source.resolve(source, opts, [])
  end

  test "source validation rejects contradictory cache semantics" do
    defmodule ContradictorySemanticsSource do
      @behaviour ImagePipe.Source

      def identifiers(_options),
        do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]

      def validate_options(opts), do: {:ok, opts}

      def resolve(%SourcePath{}, _opts, _runtime_opts) do
        {:ok,
         %Resolved{
           identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
           internal_cache: :disabled,
           http_cache: :inherit,
           cache_semantics: %CacheSemantics{
             byte_identity: {:strong, [kind: :path, root: "test", path: ["cat.jpg"]]},
             stable?: false
           },
           fetch: [path: "/tmp/cat.jpg"]
         }}
      end

      def fetch(_resolved, _opts, _runtime_opts), do: raise("not used")
    end

    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: ContradictorySemanticsSource, match: :path, options: []]]
             )

    source = %SourcePath{segments: ["cat.jpg"]}

    assert {:error, {:source, :invalid_adapter_result}} = Source.resolve(source, opts, [])
  end

  describe "named mounts" do
    defmodule PathOnlyAdapter do
      @behaviour ImagePipe.Source

      def identifiers(_options), do: [ImagePipe.Source.Path]
      def validate_options(opts), do: {:ok, opts}
      def resolve(_source, _opts, _runtime_opts), do: raise("not used")
      def fetch(_resolved, _opts, _runtime_opts), do: raise("not used")
    end

    defp mount(name, match, options \\ []),
      do: {name, [adapter: CustomAdapter, match: match, options: options]}

    defp mounted(mounts) do
      assert {:ok, config} = Source.validate_config(sources: mounts)
      config
    end

    test "validates each mount's options with its adapter, keeping the host's order" do
      config = mounted([mount(:media, [prefix: "media"], label: "root", depth: 1)])

      assert_receive {:validate_options, [label: "root", depth: 1]}
      assert {:ok, resolved} = Source.resolve(%Path{segments: ["media", "cat.jpg"]}, config, [])
      assert_receive {:resolve, _source, [label: "root", depth: 1, validated: true], []}
      assert resolved.name == :media
    end

    test "routes bare paths by prefix, stripping it, and the rest to the :path mount" do
      config = mounted([mount(:media, prefix: "media"), mount(:static, :path)])

      assert {:ok, media} = Source.resolve(%Path{segments: ["media", "a", "cat.jpg"]}, config, [])
      assert_receive {:resolve, %Path{segments: ["a", "cat.jpg"]}, _opts, []}
      assert media.name == :media

      assert {:ok, static} = Source.resolve(%Path{segments: ["other", "cat.jpg"]}, config, [])
      assert_receive {:resolve, %Path{segments: ["other", "cat.jpg"]}, _opts, []}
      assert static.name == :static
    end

    test "custom schemes reach their mount as plain paths" do
      config = mounted([mount(:assets, scheme: "asset", prefix: "assets")])

      for source <- [
            %Path{scheme: "asset", segments: ["catalog", "42"]},
            %Path{segments: ["assets", "catalog", "42"]}
          ] do
        assert {:ok, resolved} = Source.resolve(source, config, [])
        assert_receive {:resolve, %Path{scheme: nil, segments: ["catalog", "42"]}, _opts, []}
        assert resolved.name == :assets
      end
    end

    test "URL and object sources route by scheme" do
      config =
        mounted([
          mount(:web, scheme: ["http", "https"]),
          mount(:buckets, scheme: "s3")
        ])

      for scheme <- [:http, :https] do
        source = %URL{scheme: scheme, host: "example.com", path: ["cat.jpg"]}
        assert {:ok, %Resolved{name: :web}} = Source.resolve(source, config, [])
      end

      object = %ImagePipe.Source.Object{scheme: "s3", scope: "bucket", key: "cat.jpg"}
      assert {:ok, %Resolved{name: :buckets}} = Source.resolve(object, config, [])
    end

    test "fetch and cache preparation dispatch through the resolving mount" do
      config = mounted([mount(:a, [prefix: "a"], name: :a), mount(:b, [prefix: "b"], name: :b)])

      assert {:ok, resolved} = Source.resolve(%Path{segments: ["b", "cat.jpg"]}, config, [])
      assert {:ok, %Response{} = response} = Source.fetch(resolved, config, max_body_bytes: 20)
      assert Enum.to_list(response.stream) == ["image", " bytes"]
      assert_receive {:fetch, ^resolved, fetch_opts, [max_body_bytes: 20]}
      assert fetch_opts[:name] == :b

      assert {:ok, _prepared, {CustomAdapter, context_opts, _fetch}} =
               Source.prepare_cache_context(resolved, config)

      assert context_opts[:name] == :b
    end

    test "rejects paths with nothing after the prefix or with empty or dot segments" do
      config = mounted([mount(:media, prefix: "media"), mount(:static, :path)])

      for segments <- [["media"], ["media", ".."], ["a", "", "b"], [".", "cat.jpg"]] do
        assert Source.resolve(%Path{segments: segments}, config, []) ==
                 {:error, {:source, :denied_path}}
      end

      refute_received {:resolve, _source, _opts, _runtime}
    end

    test "unmatched sources fail before any adapter runs" do
      config = mounted([mount(:media, prefix: "media")])

      assert Source.resolve(%Path{segments: ["other", "cat.jpg"]}, config, []) ==
               {:error, {:source, :not_found}}

      assert {:ok, empty} = Source.validate_config(sources: [])

      assert Source.resolve(%Path{segments: ["cat.jpg"]}, empty, []) ==
               {:error, {:source, :not_found}}

      refute_received {:resolve, _source, _opts, _runtime}
    end

    test "rejects malformed mounts, overlapping rules, and unsupported source kinds" do
      for sources <- [
            [media: {CustomAdapter, []}],
            [media: [adapter: CustomAdapter, options: []]],
            [media: [adapter: CustomAdapter, match: :path, extra: true]],
            [media: [adapter: CustomAdapter, match: []]],
            [media: [adapter: CustomAdapter, match: [prefix: ""]]],
            [media: [adapter: CustomAdapter, match: [prefix: "a/b"]]],
            [media: [adapter: CustomAdapter, match: [prefix: ".."]]],
            [media: [adapter: CustomAdapter, match: [scheme: "Bad Scheme"]]],
            [media: [adapter: CustomAdapter, match: [host: "example.com"]]],
            [mount(:a, prefix: "x"), mount(:b, prefix: "x")],
            [mount(:a, scheme: "asset"), mount(:b, scheme: "asset")],
            [mount(:a, :path), mount(:b, :path)],
            [mount(:a, :path), mount(:a, prefix: "x")],
            [local: [adapter: PathOnlyAdapter, match: [scheme: "https"]]],
            [local: [adapter: PathOnlyAdapter, match: [scheme: "s3"]]],
            %{media: [adapter: CustomAdapter, match: :path]}
          ] do
        assert {:error, {:source, _reason}} = Source.validate_config(sources: sources),
               inspect(sources)
      end

      assert {:ok, _config} =
               Source.validate_config(
                 sources: [
                   local: [adapter: PathOnlyAdapter, match: [prefix: "x", scheme: "local"]]
                 ]
               )
    end
  end

  test "custom sources share originals only when their options match, apart from cache settings" do
    adapter = ImagePipe.SourceTest.ValidAdapter

    source = fn prefix, options ->
      [adapter: adapter, match: [prefix: prefix], options: options]
    end

    assert {:ok, config} =
             Source.validate_config(
               sources: [
                 photos: source.("photos", bucket: "photos"),
                 avatars: source.("avatars", bucket: "avatars"),
                 cached: source.("cached", bucket: "photos", http_cache: :inherit)
               ]
             )

    identity = fn prefix ->
      {:ok, resolved} = Source.resolve(%Path{segments: [prefix, "cat.jpg"]}, config, [])
      resolved.identity
    end

    refute identity.("photos") == identity.("avatars")
    assert identity.("photos") == identity.("cached")
  end

  test "a custom source's regex option keeps its identity when compiled again" do
    identity = fn pattern ->
      source = [
        adapter: ImagePipe.SourceTest.ValidAdapter,
        match: [prefix: "photos"],
        options: [pattern: Regex.compile!(pattern, "i")]
      ]

      {:ok, config} = Source.validate_config(sources: [photos: source])
      {:ok, resolved} = Source.resolve(%Path{segments: ["photos", "cat.jpg"]}, config, [])
      resolved.identity
    end

    assert identity.("a+") == identity.("a+")
    refute identity.("a+") == identity.("b+")
  end

  test "validate_config preserves adapter validation error context" do
    assert Source.validate_config(
             sources: [path: [adapter: InvalidConfigAdapter, match: :path, options: []]]
           ) ==
             {:error,
              {:source, {:invalid_source, :path, "{:invalid_source_config, :bad_option}"}}}
  end

  test "malformed adapter callback results become source errors" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: InvalidAdapter, match: :path, options: []]]
             )

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "malformed fetch callback results become source errors" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: InvalidAdapter, match: :path, options: []]]
             )

    resolved = %Resolved{
      name: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :content, stable?: false},
      fetch: :invalid_fetch
    }

    assert Source.fetch(resolved, opts, []) == {:error, {:source, :invalid_adapter_result}}
  end

  test "resolved identity must be cache identity material before cache or fetch can see it" do
    for identity <- [
          "https://origin.test/images/cat.jpg",
          [kind: :path, adapter_module: ImagePipe.Source.File],
          [kind: :path, lookup: %{root: "test"}],
          [kind: :path, lookup: {:root, "test"}],
          [kind: :path, client: self()]
        ] do
      assert {:ok, opts} =
               Source.validate_config(
                 sources: [
                   path: [
                     adapter: InvalidIdentityAdapter,
                     match: :path,
                     options: [identity: identity]
                   ]
                 ]
               )

      assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
               {:error, {:source, :invalid_adapter_result}}
    end
  end

  test "fetch dispatches through resolved adapter and wraps binary stream chunks" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: CustomAdapter, match: :path, options: [adapter: :path]]]
             )

    assert {:ok, resolved} = Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, opts, max_body_bytes: 20)

    assert Enum.to_list(response.stream) == ["image", " bytes"]
    assert_receive {:fetch, ^resolved, adapter_opts, [max_body_bytes: 20]}
    assert adapter_opts[:validated]
  end

  test "wrapped streams reject non-binary chunks" do
    response = %Response{stream: ["ok", :bad]}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :invalid_stream_chunk
  end

  test "wrapped streams enforce max body bytes" do
    response = %Response{stream: ["123", "456"]}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 5)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :body_too_large
  end

  test "body reduction classifies adapter failures and closes the stream" do
    stream = StreamWithCleanup.stream(self(), ["chunk"])
    stream = Stream.map(stream, fn _ -> raise "adapter failed" end)
    error = assert_raise Source.StreamError, fn -> Source.reduce_body(stream, [], &[&1 | &2]) end
    assert error.reason == :stream_exception
    assert_receive :stream_closed
  end

  test "body reduction preserves consumer failures and closes the stream" do
    stream = StreamWithCleanup.stream(self(), ["chunk"])

    assert_raise ArgumentError, "staging failed", fn ->
      Source.reduce_body(stream, [], fn _, _ -> raise ArgumentError, "staging failed" end)
    end

    assert_receive :stream_closed
  end

  test "wrap_response accepts explicit source body limit override" do
    body = :binary.copy("a", 10_000_001)
    response = %Response{stream: [body]}

    assert {:ok, %Response{} = wrapped} =
             Source.wrap_response(response, max_body_bytes: byte_size(body))

    assert Enum.to_list(wrapped.stream) == [body]
  end

  test "wrapped streams keep adapter cleanup in enumerable termination path" do
    response = %Response{stream: StreamWithCleanup.stream(self(), ["123", "456"])}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    assert Enum.take(wrapped.stream, 1) == ["123"]
    assert_receive :stream_closed
  end

  test "wrapped streams preserve safe deferred source errors" do
    response = %Response{
      stream: Stream.map([:error], fn _ -> raise Source.StreamError, reason: :bad_status end)
    }

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :bad_status
  end

  test "resolve surfaces unexpected adapter exceptions" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: RaisingAdapter, match: :path, options: []]]
             )

    assert_raise RuntimeError, "raw resolve failure", fn ->
      Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])
    end
  end

  test "fetch surfaces unexpected adapter exceptions" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [path: [adapter: RaisingAdapter, match: :path, options: []]]
             )

    resolved = %Resolved{
      name: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :content, stable?: false},
      fetch: :raise
    }

    assert_raise RuntimeError, "raw fetch failure", fn ->
      Source.fetch(resolved, opts, [])
    end
  end

  test "validate_config! raises for invalid source adapter config" do
    assert_raise ArgumentError, fn ->
      Source.validate_config!(
        sources: [path: [adapter: CustomAdapter, match: :path, options: :not_options]]
      )
    end
  end

  test "wrap_response wrapping a stream enforces the body limit on consumption" do
    {:ok, wrapped} = Source.wrap_response(%Response{stream: ["abc"]}, max_body_bytes: 2)
    assert wrapped.path == nil

    assert_raise ImagePipe.Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
  end

  test "wrap_response passes a path response through unwrapped" do
    response = %Response{path: "/tmp/x.jpg"}
    assert {:ok, ^response} = Source.wrap_response(response, max_body_bytes: 10)
  end

  test "wrap_response rejects a response carrying both a path and a stream" do
    response = %Response{path: "/tmp/x.jpg", stream: ["bytes"]}

    assert {:error, {:source, :invalid_adapter_result}} =
             Source.wrap_response(response, max_body_bytes: 10)
  end
end
