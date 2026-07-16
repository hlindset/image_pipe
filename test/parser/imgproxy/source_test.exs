defmodule ImgproxySourceTestFoobarTranslator do
  @moduledoc false
  @behaviour ImagePipe.Parser.Imgproxy.SourceScheme

  alias ImagePipe.Plan.Source.Object

  @impl true
  def translate(source, opts) do
    send(self(), {:translate, source, opts})
    {:ok, %Object{adapter: :foobar, scope: "scope", key: source, revision: "r1"}}
  end
end

defmodule ImgproxySourceTestFailingTranslator do
  @moduledoc false
  @behaviour ImagePipe.Parser.Imgproxy.SourceScheme

  @impl true
  def translate(_source, _opts), do: {:error, {:secret_path, "/private/cat.jpg"}}
end

for {impl, suffix} <- [
      {ImagePipe.Parser.Imgproxy.Source, Framework},
      {ImagePipe.Dialect.Imgproxy.Source, Dialect}
    ] do
  defmodule Module.concat(ImgproxySourceTest, suffix) do
    use ExUnit.Case, async: true

    alias ImagePipe.Plan.Source.Object
    alias ImagePipe.Plan.Source.Path
    alias ImagePipe.Plan.Source.URL

    @source impl
    @foobar_translator ImgproxySourceTestFoobarTranslator
    @failing_translator ImgproxySourceTestFailingTranslator

    test "plain path translates to path source" do
      assert @source.translate("images/cat.jpg", []) ==
               {:ok, %Path{segments: ["images", "cat.jpg"]}}
    end

    test "local scheme translates to the same path source shape as plain path" do
      assert @source.translate("local:///images/cat.jpg", []) ==
               {:ok, %Path{segments: ["images", "cat.jpg"]}}
    end

    test "plain and local sources reject empty path segments after signature verification" do
      assert @source.translate("images//cat.jpg/", []) ==
               {:error, :invalid_source_path}

      assert @source.translate("local:///images//cat.jpg/", []) ==
               {:error, :invalid_source_path}
    end

    test "plain path sources reject escaped source query material" do
      assert @source.translate("images/cat.jpg%3Fv=1", []) ==
               {:error, {:unsupported_source_query, "path"}}
    end

    test "http and https translate to url source" do
      assert @source.translate("https://assets.example.com/images/cat.jpg?v=1", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: nil,
                  path: ["images", "cat.jpg"],
                  query: "v=1"
                }}

      assert @source.translate("http://assets.example.com:8080/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :http,
                  host: "assets.example.com",
                  port: 8080,
                  path: ["cat.jpg"],
                  query: nil
                }}
    end

    test "url sources keep explicit default ports but omit implicit default ports" do
      assert @source.translate("https://assets.example.com/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: nil,
                  path: ["cat.jpg"],
                  query: nil
                }}

      assert @source.translate("https://assets.example.com:443/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: 443,
                  path: ["cat.jpg"],
                  query: nil
                }}

      assert @source.translate("http://assets.example.com/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :http,
                  host: "assets.example.com",
                  port: nil,
                  path: ["cat.jpg"],
                  query: nil
                }}

      assert @source.translate("http://assets.example.com:80/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :http,
                  host: "assets.example.com",
                  port: 80,
                  path: ["cat.jpg"],
                  query: nil
                }}
    end

    test "url sources reject malformed explicit ports" do
      for source <- [
            "https://assets.example.com:abc/cat.jpg",
            "https://assets.example.com:/cat.jpg",
            "https://assets.example.com:+443/cat.jpg",
            "https://assets.example.com:99999/cat.jpg",
            "http://[::1]:abc/cat.jpg"
          ] do
        assert @source.translate(source, []) == {:error, :invalid_source_url}
      end
    end

    test "url sources detect IPv6 explicit ports without treating IPv6 colons as a port" do
      assert @source.translate("http://[::1]/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :http,
                  host: "::1",
                  port: nil,
                  path: ["cat.jpg"],
                  query: nil
                }}

      assert @source.translate("http://[::1]:8080/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :http,
                  host: "::1",
                  port: 8080,
                  path: ["cat.jpg"],
                  query: nil
                }}
    end

    test "http escaped query delimiter becomes query and double-escaped delimiter stays in path" do
      assert @source.translate("https://assets.example.com/images/cat.jpg%3Fv=1", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: nil,
                  path: ["images", "cat.jpg"],
                  query: "v=1"
                }}

      assert @source.translate("https://assets.example.com/images/cat.jpg%3Fv=a%26b%3Dc", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: nil,
                  path: ["images", "cat.jpg"],
                  query: "v=a%26b%3Dc"
                }}

      assert @source.translate("https://assets.example.com/images/cat%253Fone.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: nil,
                  path: ["images", "cat%3Fone.jpg"],
                  query: nil
                }}
    end

    test "url sources normalize mixed-case hosts before identity resolution" do
      assert @source.translate("https://Assets.Example.Com/cat.jpg", []) ==
               {:ok,
                %URL{
                  scheme: :https,
                  host: "assets.example.com",
                  port: nil,
                  path: ["cat.jpg"],
                  query: nil
                }}
    end

    test "s3 translates URI host and path to object source with raw query as revision" do
      assert @source.translate("s3://bucket/images/cat.jpg?abc", []) ==
               {:ok,
                %Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: "abc"}}

      assert @source.translate("s3://bucket/images/cat.jpg%3Fabc", []) ==
               {:ok,
                %Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: "abc"}}

      assert @source.translate("s3://bucket/images/cat.jpg%3Fa%26b%3Dc", []) ==
               {:ok,
                %Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: "a&b=c"}}

      assert @source.translate("s3://bucket/images/cat.jpg?version=abc", []) ==
               {:ok,
                %Object{
                  adapter: :s3,
                  scope: "bucket",
                  key: "images/cat.jpg",
                  revision: "version=abc"
                }}
    end

    test "s3 rejects URI userinfo and ports that object sources cannot represent" do
      for source <- [
            "s3://user@bucket/images/cat.jpg",
            "s3://bucket:9000/images/cat.jpg"
          ] do
        assert @source.translate(source, []) == {:error, :invalid_source_object}
      end
    end

    test "s3 preserves empty key components because object keys are opaque" do
      assert @source.translate("s3://bucket/images//cat.jpg/", []) ==
               {:ok,
                %Object{adapter: :s3, scope: "bucket", key: "images//cat.jpg/", revision: nil}}

      assert @source.translate("s3://bucket//cat.jpg", []) ==
               {:ok, %Object{adapter: :s3, scope: "bucket", key: "/cat.jpg", revision: nil}}
    end

    test "object and local keys decode escaped reserved characters after URI structure is parsed" do
      assert @source.translate("s3://bucket/images/cat%23one%25two.jpg?abc", []) ==
               {:ok,
                %Object{
                  adapter: :s3,
                  scope: "bucket",
                  key: "images/cat#one%two.jpg",
                  revision: "abc"
                }}

      assert @source.translate("local:///images/cat%23one%25two.jpg", []) ==
               {:ok, %Path{segments: ["images", "cat#one%two.jpg"]}}
    end

    test "double-escaped query delimiters stay in object and local source paths" do
      assert @source.translate("s3://bucket/images/cat%253Fone.jpg", []) ==
               {:ok,
                %Object{
                  adapter: :s3,
                  scope: "bucket",
                  key: "images/cat%3Fone.jpg",
                  revision: nil
                }}

      assert @source.translate("local:///images/cat%253Fone.jpg", []) ==
               {:ok, %Path{segments: ["images", "cat%3Fone.jpg"]}}
    end

    test "first slice treats escaped query separators as non-HTTP source query separators" do
      assert @source.translate("s3://bucket/images/cat.jpg%3Fabc", []) ==
               {:ok,
                %Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: "abc"}}

      assert @source.translate("local:///images/cat.jpg%3Fabc", []) ==
               {:error, {:unsupported_source_query, "local"}}
    end

    test "unknown schemes fail unless configured with a binary-keyed translator map" do
      assert @source.translate("foobar://thing/cat.jpg", []) ==
               {:error, {:unsupported_source_scheme, "foobar"}}

      assert @source.translate("foobar://thing/cat.jpg",
               source_schemes: %{"foobar" => {@foobar_translator, color: "blue"}}
             ) ==
               {:ok,
                %Object{
                  adapter: :foobar,
                  scope: "scope",
                  key: "foobar://thing/cat.jpg",
                  revision: "r1"
                }}

      assert_receive {:translate, "foobar://thing/cat.jpg", [color: "blue"]}
    end

    test "custom translators receive decoded source strings" do
      assert @source.translate("foobar://asset/cat%23one%3Fv",
               source_schemes: %{"foobar" => {@foobar_translator, []}}
             ) ==
               {:ok,
                %Object{
                  adapter: :foobar,
                  scope: "scope",
                  key: "foobar://asset/cat#one?v",
                  revision: "r1"
                }}

      assert_receive {:translate, "foobar://asset/cat#one?v", []}
    end

    test "custom translator errors are normalized before parser error responses inspect them" do
      assert @source.translate("foobar://thing/cat.jpg",
               source_schemes: %{"foobar" => {@failing_translator, []}}
             ) == {:error, {:source_scheme_error, "foobar"}}
    end
  end
end
