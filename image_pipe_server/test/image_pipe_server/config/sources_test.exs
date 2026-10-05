defmodule ImagePipeServer.Config.SourcesTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.AssumeRole
  alias ImagePipe.Source.S3.InstanceRole
  alias ImagePipeServer.Config.Sources
  alias ImagePipeServer.ConfigError

  defp convert(table), do: Sources.options!(table)

  defp error(table), do: assert_raise(ConfigError, fn -> convert(table) end).message

  describe "adapter and match" do
    test "name a built-in adapter and a path match" do
      assert convert(%{
               "static" => %{
                 "adapter" => "file",
                 "match" => "path",
                 "root" => "/data",
                 "root_id" => "static"
               }
             }) == [
               static: [
                 adapter: ImagePipe.Source.File,
                 match: :path,
                 options: [root: "/data", root_id: "static"]
               ]
             ]
    end

    test "accept prefix and scheme rules, as strings or lists" do
      [tmdb: mount] =
        convert(%{
          "tmdb" => %{
            "adapter" => "http",
            "match" => %{"prefix" => "tmdb", "scheme" => ["tmdb", "movie"]},
            "base_url" => "https://example.com"
          }
        })

      assert mount[:match] == [prefix: "tmdb", scheme: ["tmdb", "movie"]]
    end

    test "read match rules from the environment" do
      [web: mount] =
        convert(%{
          "web" => %{
            "adapter" => {:env, "http"},
            "match" => %{"scheme" => {:env, "http,https"}},
            "allowed_hosts" => {:env, "a.example,b.example"}
          }
        })

      assert mount[:adapter] == ImagePipe.Source.HTTP
      assert mount[:match] == [scheme: ["http", "https"]]
      assert mount[:options] == [allowed_hosts: ["a.example", "b.example"]]
    end

    test "require an adapter and a match" do
      assert error(%{"a" => %{"match" => "path"}}) =~ "sources.a.adapter: required"
      assert error(%{"a" => %{"adapter" => "file"}}) =~ "sources.a.match: required"
    end

    test "reject unknown adapters" do
      assert error(%{"a" => %{"adapter" => "ftp", "match" => "path"}}) =~
               "sources.a.adapter: expected one of file, http, s3"
    end
  end

  describe "HTTP mounts" do
    test "compile path_pattern" do
      [tmdb: mount] =
        convert(%{
          "tmdb" => %{
            "adapter" => "http",
            "match" => %{"prefix" => "tmdb"},
            "base_url" => "https://example.com",
            "path_pattern" => "[a-z]+\\.jpg"
          }
        })

      assert %Regex{source: "[a-z]+\\.jpg"} = mount[:options][:path_pattern]
    end

    test "name an invalid path_pattern" do
      assert error(%{
               "a" => %{"adapter" => "http", "match" => "path", "path_pattern" => "("}
             }) =~ "sources.a.path_pattern: invalid regular expression"
    end

    test "turn request_headers and bearer_token into req_options" do
      [api: mount] =
        convert(%{
          "api" => %{
            "adapter" => "http",
            "match" => "path",
            "base_url" => "https://example.com",
            "request_headers" => %{"x-api-key" => "k"},
            "bearer_token" => {:env, "t"}
          }
        })

      assert mount[:options][:req_options] == [
               headers: [{"x-api-key", "k"}],
               auth: {:bearer, "t"}
             ]

      refute Keyword.has_key?(mount[:options], :request_headers)
      refute Keyword.has_key?(mount[:options], :bearer_token)
    end

    test "reject a request header value with a line break and quote nothing" do
      message =
        error(%{
          "api" => %{
            "adapter" => "http",
            "match" => "path",
            "request_headers" => %{"x-api-key" => "sekrit\nInjected: 1"}
          }
        })

      assert message =~ "sources.api.request_headers.x-api-key: invalid header value"
      refute message =~ "sekrit"
    end

    test "reject a request header name that isn't a token" do
      assert error(%{
               "api" => %{
                 "adapter" => "http",
                 "match" => "path",
                 "request_headers" => %{"bad name" => "v"}
               }
             }) =~ "sources.api.request_headers.bad name: invalid header name"
    end

    test "reject an empty bearer_token" do
      assert error(%{
               "api" => %{"adapter" => "http", "match" => "path", "bearer_token" => ""}
             }) =~ "sources.api.bearer_token: expected a non-empty string"
    end

    test "accept the keyword form of address_policy" do
      [web: mount] =
        convert(%{
          "web" => %{
            "adapter" => "http",
            "match" => %{"scheme" => "https"},
            "allowed_hosts" => ["img.internal"],
            "address_policy" => %{"allow_private" => true, "allow" => ["10.0.0.0/8"]}
          }
        })

      assert Enum.sort(mount[:options][:address_policy]) ==
               [allow: ["10.0.0.0/8"], allow_private: true]
    end

    test "keep req_options Elixir-only" do
      assert error(%{
               "a" => %{
                 "adapter" => "http",
                 "match" => "path",
                 "req_options" => %{"retry" => false}
               }
             }) =~ "sources.a.req_options: not supported in the configuration file"
    end
  end

  test "convert cache_policy" do
    [static: mount] =
      convert(%{
        "static" => %{
          "adapter" => "file",
          "match" => "path",
          "stable" => "immutable",
          "cache_policy" => %{"storage" => "allow", "freshness" => %{"fallback" => 60}}
        }
      })

    assert mount[:options][:stable] == :immutable

    assert Enum.sort(mount[:options][:cache_policy]) == [
             freshness: {:fallback, 60},
             storage: :allow
           ]
  end

  describe "S3 mounts" do
    test "put shared settings under default and keep buckets by name" do
      [media: mount] =
        convert(%{
          "media" => %{
            "adapter" => "s3",
            "match" => %{"scheme" => "s3"},
            "region" => "us-east-1",
            "endpoint" => "https://s3.example.com",
            "credentials" => %{
              "static" => %{"access_key_id" => "id", "secret_access_key" => {:env, "secret"}}
            },
            "buckets" => %{"photos" => %{"region" => "eu-west-1"}}
          }
        })

      assert mount[:adapter] == ImagePipe.Source.S3
      default = mount[:options][:default]
      assert default[:region] == "us-east-1"
      assert default[:endpoint] == "https://s3.example.com"

      assert {:static, credentials} = default[:credentials]
      assert Enum.sort(credentials) == [access_key_id: "id", secret_access_key: "secret"]
      assert mount[:options][:buckets] == %{"photos" => [region: "eu-west-1"]}
    end

    test "name a credential provider and its options" do
      [media: mount] =
        convert(%{
          "media" => %{
            "adapter" => "s3",
            "match" => %{"scheme" => "s3"},
            "credentials" => %{
              "provider" => "assume_role",
              "role_arn" => "arn:aws:iam::1:role/r",
              "region" => "us-east-1",
              "base" => %{"provider" => "instance_role", "ttl_seconds" => 300}
            }
          }
        })

      assert {:provider, AssumeRole, options} = mount[:options][:default][:credentials]
      assert options[:role_arn] == "arn:aws:iam::1:role/r"
      assert options[:base] == {:provider, InstanceRole, [ttl_seconds: 300]}
    end

    test "take web_identity's token_file from a _FILE variable" do
      [media: mount] =
        convert(%{
          "media" => %{
            "adapter" => "s3",
            "match" => %{"scheme" => "s3"},
            "credentials" => %{
              "provider" => {:env, "web_identity"},
              "role_arn" => "arn:aws:iam::1:role/r",
              "region" => "us-east-1",
              "token" =>
                {:env_file, "IPS_SOURCES__MEDIA__CREDENTIALS__TOKEN_FILE", "/var/run/token"}
            }
          }
        })

      assert {:provider, ImagePipe.Source.S3.WebIdentity, options} =
               mount[:options][:default][:credentials]

      assert options[:token_file] == "/var/run/token"
    end

    test "reject unknown credential providers without echoing credentials" do
      message =
        error(%{
          "media" => %{
            "adapter" => "s3",
            "match" => %{"scheme" => "s3"},
            "credentials" => %{"static" => %{"access_key_id" => "id", "secrett" => "hunter2"}}
          }
        })

      assert message =~ "sources.media.credentials.static.secrett: unknown setting"
      refute message =~ "hunter2"
    end
  end
end
