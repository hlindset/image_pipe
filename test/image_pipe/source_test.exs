defmodule ImagePipe.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.SourceTest.AdapterMismatchAdapter
  alias ImagePipe.SourceTest.CustomAdapter
  alias ImagePipe.SourceTest.InvalidAdapter
  alias ImagePipe.SourceTest.InvalidConfigAdapter
  alias ImagePipe.SourceTest.InvalidIdentityAdapter
  alias ImagePipe.SourceTest.RaisingAdapter
  alias ImagePipe.SourceTest.StreamWithCleanup

  test "source validation rejects resolved values without cache semantics" do
    defmodule MissingSemanticsSource do
      @behaviour ImagePipe.Source

      def validate_options(opts), do: {:ok, opts}

      def resolve(%SourcePath{}, _opts, _runtime_opts) do
        {:ok,
         %Resolved{
           adapter: :path,
           source_kind: :path,
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
               parser: ImagePipe.Parser.IIIF,
               sources: [path: {MissingSemanticsSource, []}]
             )

    source = %SourcePath{segments: ["cat.jpg"]}

    assert {:error, {:source, :invalid_adapter_result}} = Source.resolve(source, opts, [])
  end

  test "source validation rejects contradictory cache semantics" do
    defmodule ContradictorySemanticsSource do
      @behaviour ImagePipe.Source

      def validate_options(opts), do: {:ok, opts}

      def resolve(%SourcePath{}, _opts, _runtime_opts) do
        {:ok,
         %Resolved{
           adapter: :path,
           source_kind: :path,
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
               parser: ImagePipe.Parser.IIIF,
               sources: [path: {ContradictorySemanticsSource, []}]
             )

    source = %SourcePath{segments: ["cat.jpg"]}

    assert {:error, {:source, :invalid_adapter_result}} = Source.resolve(source, opts, [])
  end

  test "validate_config calls adapter validation during init-time option normalization" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 path: {CustomAdapter, adapter: :path, label: "root"}
               ]
             )

    assert_receive {:validate_options, [adapter: :path, label: "root"]}

    assert opts[:sources][:path] ==
             {CustomAdapter, [adapter: :path, label: "root", validated: true]}
  end

  test "validate_config preserves adapter validation error context" do
    assert Source.validate_config(sources: [path: {InvalidConfigAdapter, []}]) ==
             {:error, {:source, {:invalid_source_config, :bad_option}}}
  end

  test "resolve dispatches by source shape and configured adapter key" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 path: {CustomAdapter, adapter: :path}
               ]
             )

    source = %Path{segments: ["images", "cat.jpg"]}

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, request_id: "r1")
    assert resolved.adapter == :path
    assert resolved.source_kind == :path
    assert resolved.identity == [kind: :path, root: "test", path: ["images", "cat.jpg"]]
    assert resolved.internal_cache == :enabled

    assert_receive {:resolve, ^source, adapter_opts, [request_id: "r1"]}
    assert adapter_opts[:validated]
  end

  test "missing configured adapter fails before cache or fetch" do
    assert {:ok, opts} = Source.validate_config(sources: [])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :missing_adapter}}
  end

  test "url source config enables both HTTP and HTTPS adapters" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end

    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 url:
                   {HTTP,
                    allowed_hosts: ["assets.example.com"],
                    req_options: [plug: plug],
                    address_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end}
               ]
             )

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, [])
    assert resolved.adapter == :https
    assert resolved.identity[:adapter] == :https

    assert {:ok, %Response{} = response} = Source.fetch(resolved, opts, max_body_bytes: 20)
    assert Enum.join(response.stream) == "image bytes"

    assert Map.has_key?(opts[:sources], :http)
    assert Map.has_key?(opts[:sources], :https)
    refute Map.has_key?(opts[:sources], :url)
  end

  test "scheme-specific source config overrides url source config" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 url: {HTTP, allowed_hosts: ["assets.example.com"]},
                 https: {HTTP, allowed_hosts: ["assets.example.com"], internal_cache: :disabled}
               ]
             )

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, [])
    assert resolved.internal_cache == :disabled
  end

  test "malformed adapter callback results become source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {InvalidAdapter, []}])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "malformed fetch callback results become source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {InvalidAdapter, []}])

    resolved = %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
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
                 sources: [path: {InvalidIdentityAdapter, identity: identity}]
               )

      assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
               {:error, {:source, :invalid_adapter_result}}
    end
  end

  test "resolved adapter must match the adapter key selected during resolution" do
    assert {:ok, opts} = Source.validate_config(sources: [foobar: {AdapterMismatchAdapter, []}])

    source = %ImagePipe.Plan.Source.Object{adapter: :foobar, scope: "scope", key: "cat.jpg"}

    assert Source.resolve(source, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "fetch dispatches through resolved adapter and wraps binary stream chunks" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {CustomAdapter, adapter: :path}])
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
    assert {:ok, opts} = Source.validate_config(sources: [path: {RaisingAdapter, []}])

    assert_raise RuntimeError, "raw resolve failure", fn ->
      Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])
    end
  end

  test "fetch surfaces unexpected adapter exceptions" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {RaisingAdapter, []}])

    resolved = %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
      fetch: :raise
    }

    assert_raise RuntimeError, "raw fetch failure", fn ->
      Source.fetch(resolved, opts, [])
    end
  end

  test "validate_config! raises for invalid source adapter config" do
    assert_raise ArgumentError, fn ->
      Source.validate_config!(sources: [path: {CustomAdapter, :not_options}])
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
