defmodule ImagePipeServer.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipeServer.Config
  alias ImagePipeServer.ConfigError

  @key32 :binary.copy(<<7>>, 32)

  defp error(fun), do: assert_raise(ConfigError, fun).message

  describe "options!/1" do
    test "rejects unknown sections" do
      assert error(fn -> Config.options!(%{"servr" => %{}}) end) =~ "servr: unknown setting"
    end

    test "converts [url], keeping hex source-encryption keys as given" do
      hex = Base.encode16(@key32, case: :lower)

      url =
        Config.options!(%{
          "url" => %{
            "keys" => {:env, "aa,bb"},
            "source_encryption_keys" => [hex, String.upcase(hex)]
          }
        })[:url]

      assert url[:keys] == ["aa", "bb"]
      assert url[:source_encryption_keys] == [hex, String.upcase(hex)]
    end

    test "converts presets and request defaults in [processing]" do
      processing =
        Config.options!(%{
          "processing" => %{
            "presets" => %{"card" => "w=400/h=400"},
            "request_defaults" => "q=80"
          }
        })[:processing]

      assert processing[:presets] == %{"card" => "w=400/h=400"}
      assert processing[:request_defaults] == "q=80"
    end

    test "rejects source-encryption keys that aren't 32 hex-encoded bytes without echoing them" do
      for key <- ["sekritzz", String.duplicate("ab", 31), "base64:" <> Base.encode64(@key32)] do
        message =
          error(fn -> Config.options!(%{"url" => %{"source_encryption_keys" => [key]}}) end)

        assert message ==
                 "invalid configuration: url.source_encryption_keys[0]: expected a hex-encoded 32-byte key"

        refute message =~ key
      end
    end

    test "keeps builder-only settings out of [url]" do
      for {key, value} <- [{"base_url", "/x"}, {"encrypt_source", true}, {"iv_mode", "random"}] do
        assert error(fn -> Config.options!(%{"url" => %{key => value}}) end) =~
                 "url.#{key}: unknown setting"
      end
    end

    test "rejects output_capabilities in [processing]" do
      assert error(fn ->
               Config.options!(%{"processing" => %{"output_capabilities" => %{"avif" => true}}})
             end) =~ "processing.output_capabilities: unknown setting"
    end

    test "converts [cache] to FileSystem caches and storage inputs" do
      cache =
        Config.options!(%{
          "cache" => %{
            "output" => %{"root" => "/var/cache/out", "max_size_bytes" => 1_000_000},
            "input" => %{"root" => {:env, "/var/cache/in"}},
            "storage_inputs" => [%{"header" => "x-tenant"}]
          }
        })[:cache]

      assert {FileSystem, output} = cache[:cache]
      assert Enum.sort(output) == [max_size_bytes: 1_000_000, root: "/var/cache/out"]
      assert cache[:input_cache] == {FileSystem, [root: "/var/cache/in"]}
      assert cache[:storage_inputs] == [{:header, "x-tenant"}]
    end

    test "converts [processing], including encoder options" do
      processing =
        Config.options!(%{
          "processing" => %{
            "quality" => {:env, "82"},
            "format_quality" => %{"webp" => 80},
            "format_order" => ["webp", "avif"],
            "skip_processing_formats" => ["gif", "jpeg_xl"],
            "jpeg_options" => %{"interlace" => true, "quant_table" => 3},
            "source_cache_policy" => %{"freshness" => "origin"}
          }
        })[:processing]

      assert processing[:quality] == 82
      assert processing[:format_quality] == %{webp: 80}
      assert processing[:format_order] == [:webp, :avif]
      assert processing[:skip_processing_formats] == [:gif, :jpeg_xl]
      assert processing[:jpeg_options] == [interlace: true, quant_table: 3]
      assert processing[:source_cache_policy] == [freshness: :origin]
    end

    test "keeps Elixir-only processing settings out of the file" do
      for key <- ["clock", "preset_lookup", "max_preset_lookups"] do
        assert error(fn -> Config.options!(%{"processing" => %{key => 1}}) end) =~
                 "processing.#{key}: not supported in the configuration file"
      end
    end
  end

  describe "build!/1" do
    test "fills server defaults" do
      config = Config.build!(Config.options!(%{}))

      assert config.server == [
               port: 8080,
               ip: {0, 0, 0, 0},
               mount_path: "/",
               shutdown_timeout: 15_000,
               read_timeout: 10_000,
               max_connections: 2048,
               auth_token_hash: nil
             ]

      assert config.pool == nil
      assert config.image_pipe.options[:processing_pool] == nil
      assert config.telemetry == nil
      assert config.trust_traceparent == false
    end

    test "parses the bind address and checks the mount path" do
      server = %{"port" => {:env, "9000"}, "bind" => "::1", "mount_path" => "/images"}
      config = Config.build!(Config.options!(%{"server" => server}))
      assert config.server[:port] == 9000
      assert config.server[:ip] == {0, 0, 0, 0, 0, 0, 0, 1}
      assert config.server[:mount_path] == "/images"

      assert error(fn -> Config.build!(Config.options!(%{"server" => %{"bind" => "host"}})) end) =~
               "server.bind: expected an IP address"

      assert error(fn ->
               Config.build!(Config.options!(%{"server" => %{"mount_path" => "images"}}))
             end) =~ "server.mount_path: expected a path starting with /"
    end

    test "passes [processing] watermarks to the library by name" do
      config =
        Config.build!(
          Config.options!(%{
            "sources" => %{
              "files" => %{
                "adapter" => "file",
                "match" => "path",
                "root" => "/srv/images",
                "root_id" => "images"
              }
            },
            "processing" => %{
              "watermarks" => %{"logo" => %{"source" => "brand/logo.png", "opacity" => 0.5}},
              "request_watermarks" => true
            }
          })
        )

      assert %{"logo" => %{opacity: 0.5}} = config.image_pipe.options[:watermarks]
      assert config.image_pipe.options[:request_watermarks] == true

      assert error(fn ->
               Config.build!(
                 Config.options!(%{
                   "processing" => %{"watermarks" => %{"logo" => %{"opacity" => 0.5}}}
                 })
               )
             end) =~ "watermark logo: required :source option"
    end

    test "validates [pool] and [telemetry]" do
      config =
        Config.build!(
          Config.options!(%{
            "pool" => %{"max_concurrency" => 4},
            "telemetry" => %{"log_level" => "debug", "trust_traceparent" => true}
          })
        )

      assert config.pool[:max_concurrency] == 4
      assert config.image_pipe.options[:processing_pool] == config.pool[:name]
      assert config.telemetry == [level: :debug]
      assert config.trust_traceparent == true

      assert error(fn -> Config.build!(Config.options!(%{"pool" => %{"max_queue" => 1}})) end) =~
               "pool"
    end

    test "builds validated mount options" do
      config =
        Config.build!(
          Config.options!(%{
            "processing" => %{"quality" => 70},
            "http" => %{"http_cache" => "auto", "allow_origin" => "*"}
          })
        )

      assert config.image_pipe.options[:quality] == 70
      assert config.http[:allow_origin] == "*"
      assert config.http[:http_cache] == :auto
    end

    test "reports library validation errors" do
      assert error(fn ->
               Config.build!(Config.options!(%{"processing" => %{"quality" => 500}}))
             end) =~
               "quality"
    end

    test "keeps only a hash of the auth token" do
      config = Config.build!(Config.options!(%{"server" => %{"auth_token" => {:env, "sekrit"}}}))

      assert config.server[:auth_token_hash] == :crypto.hash(:sha256, "sekrit")
      refute inspect(config) =~ "sekrit"
    end

    test "rejects an empty auth token" do
      assert error(fn -> Config.build!(Config.options!(%{"server" => %{"auth_token" => ""}})) end) =~
               "server.auth_token"
    end

    test "rejects a port above 65535" do
      assert error(fn -> Config.build!(Config.options!(%{"server" => %{"port" => 70_000}})) end) =~
               "server.port"

      assert Config.build!(Config.options!(%{"server" => %{"port" => 65_535}})).server[:port] ==
               65_535
    end

    test "takes the shutdown grace period from [server]" do
      config = Config.build!(Config.options!(%{"server" => %{"shutdown_timeout" => 30_000}}))
      assert config.server[:shutdown_timeout] == 30_000
    end

    test "rejects a required detector the build doesn't have" do
      assert error(fn ->
               Config.build!(Config.options!(%{"processing" => %{"detector_required" => true}}))
             end) =~ "detector_required: the detector is not available in this build"
    end

    test "warms S3 credential providers for each named bucket" do
      provider = %{"provider" => "instance_role", "ttl_seconds" => 300}

      config =
        Config.build!(
          Config.options!(%{
            "sources" => %{
              "media" => %{
                "adapter" => "s3",
                "match" => %{"scheme" => "s3"},
                "region" => "us-east-1",
                "endpoint" => "https://s3.example.com",
                "credentials" => provider,
                "buckets" => %{
                  "inherits" => %{},
                  "static" => %{
                    "credentials" => %{
                      "static" => %{"access_key_id" => "a", "secret_access_key" => "b"}
                    }
                  }
                }
              }
            }
          })
        )

      assert config.credential_warmups == [
               [
                 provider: ImagePipe.Source.S3.InstanceRole,
                 opts: [ttl_seconds: 300],
                 scope: "inherits"
               ]
             ]
    end

    test "never echoes invalid signing keys" do
      message =
        error(fn ->
          Config.build!(Config.options!(%{"url" => %{"keys" => ["sekrit-not-hex"]}}))
        end)

      refute message =~ "sekrit"
    end
  end

  describe "load!/2" do
    @describetag :tmp_dir

    test "reads the file and lets the environment override it", %{tmp_dir: dir} do
      images = Path.join(dir, "images")
      File.mkdir_p!(images)
      path = Path.join(dir, "config.toml")

      File.write!(path, """
      [server]
      port = 9000

      [processing]
      quality = 82

      [sources.static]
      adapter = "file"
      match = "path"
      root = "#{images}"
      root_id = "static"
      """)

      config =
        Config.load!(
          %{"IPS_CONFIG" => path, "IPS_PROCESSING__QUALITY" => "75"},
          Path.join(dir, "absent.toml")
        )

      assert config.server[:port] == 9000
      assert config.image_pipe.options[:quality] == 75
    end

    defp s3_provider_config(dir, provider) do
      path = Path.join(dir, "config.toml")

      File.write!(path, """
      [sources.media]
      adapter = "s3"
      match = { scheme = "s3" }
      region = "us-east-1"
      endpoint = "https://s3.example.com"
      credentials = #{provider}
      buckets = { photos = {} }
      """)

      path
    end

    defp warmup_options(path, env) do
      [warmup] = Config.load!(Map.put(env, "IPS_CONFIG", path), "absent.toml").credential_warmups
      Keyword.fetch!(warmup, :opts)
    end

    test "fills container credentials from the AWS variables", %{tmp_dir: dir} do
      env = %{
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" => "/v2/credentials/abc",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI" => "http://127.0.0.1:1234/creds",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN" => "token",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE" => "/var/run/token"
      }

      path = s3_provider_config(dir, ~s|{ provider = "container_credentials" }|)

      assert Enum.sort(warmup_options(path, env)) == [
               auth_token: "token",
               auth_token_file: "/var/run/token",
               full_uri: "http://127.0.0.1:1234/creds",
               relative_uri: "/v2/credentials/abc"
             ]

      path =
        s3_provider_config(
          dir,
          ~s|{ provider = "container_credentials", relative_uri = "/mine" }|
        )

      assert warmup_options(path, env) == [relative_uri: "/mine"]
    end

    test "rejects an empty signing-keys file", %{tmp_dir: dir} do
      keys = Path.join(dir, "keys")
      File.write!(keys, "\n")

      assert error(fn ->
               Config.load!(%{"IPS_URL__KEYS_FILE" => keys}, Path.join(dir, "absent.toml"))
             end) =~ "url.keys: expected at least one entry"
    end

    test "takes a container credentials token file as a path, read at refresh", %{tmp_dir: dir} do
      token = Path.join(dir, "token")
      File.write!(token, "rotating")

      env = %{
        "IPS_SOURCES__MEDIA__CREDENTIALS__AUTH_TOKEN_FILE" => token,
        "AWS_CONTAINER_CREDENTIALS_FULL_URI" => "http://127.0.0.1:1234/creds"
      }

      path = s3_provider_config(dir, ~s|{ provider = "container_credentials" }|)

      assert warmup_options(path, env) == [auth_token_file: token]
    end

    test "fills web identity options from the AWS variables", %{tmp_dir: dir} do
      env = %{
        "AWS_WEB_IDENTITY_TOKEN_FILE" => "/var/run/token",
        "AWS_ROLE_ARN" => "arn:aws:iam::1:role/env",
        "AWS_REGION" => "eu-west-1",
        "AWS_ROLE_SESSION_NAME" => "session"
      }

      path =
        s3_provider_config(
          dir,
          ~s|{ provider = "assume_role", role_arn = "arn:aws:iam::1:role/target", region = "us-east-1", base = { provider = "web_identity", role_arn = "arn:aws:iam::1:role/mine" } }|
        )

      assert {:provider, ImagePipe.Source.S3.WebIdentity, base} =
               Keyword.fetch!(warmup_options(path, env), :base)

      assert Enum.sort(base) == [
               region: "eu-west-1",
               role_arn: "arn:aws:iam::1:role/mine",
               role_session_name: "session",
               token_file: "/var/run/token"
             ]
    end
  end
end
