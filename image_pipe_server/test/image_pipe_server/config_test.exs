defmodule ImagePipeServer.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Plan.Output.JpegOptions
  alias ImagePipeServer.Config
  alias ImagePipeServer.ConfigError

  @key32 :binary.copy(<<7>>, 32)

  defp error(fun), do: assert_raise(ConfigError, fun).message

  describe "options!/1" do
    test "rejects unknown sections" do
      assert error(fn -> Config.options!(%{"servr" => %{}}) end) =~ "servr: unknown setting"
    end

    test "converts [url], decoding prefixed source-encryption keys" do
      url =
        Config.options!(%{
          "url" => %{
            "keys" => {:env, "aa,bb"},
            "source_encryption_keys" => [
              "base64:" <> Base.encode64(@key32),
              "hex:" <> Base.encode16(@key32)
            ],
            "iv_mode" => "random"
          }
        })[:url]

      assert url[:keys] == ["aa", "bb"]
      assert url[:source_encryption_keys] == [@key32, @key32]
      assert url[:iv_mode] == :random
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

    test "rejects unprefixed or undecodable source-encryption keys without echoing them" do
      for key <- ["c2VrcmV0", "base64:!!sekrit!!", "hex:sekritzz"] do
        message =
          error(fn -> Config.options!(%{"url" => %{"source_encryption_keys" => [key]}}) end)

        assert message =~ "url.source_encryption_keys[0]"
        refute message =~ "sekrit"
        refute message =~ "c2VrcmV0"
      end
    end

    test "keeps base_url out of [url]" do
      assert error(fn -> Config.options!(%{"url" => %{"base_url" => "/x"}}) end) =~
               "url.base_url: unknown setting"
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

    test "converts [processing], including encoder option structs" do
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
      assert processing[:jpeg_options] == %JpegOptions{interlace: true, quant_table: 3}
      assert processing[:source_cache_policy] == [freshness: :origin]
    end

    test "keeps function-valued processing settings Elixir-only" do
      assert error(fn -> Config.options!(%{"processing" => %{"clock" => 1}}) end) =~
               "processing.clock: not supported in the configuration file"
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
      assert config.image_pipe[:processing_pool] == nil
      assert config.telemetry == nil
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

      assert %{"logo" => %{opacity: 0.5}} = config.image_pipe[:watermarks]
      assert config.image_pipe[:request_watermarks] == true

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
            "telemetry" => %{"log_level" => "debug"}
          })
        )

      assert config.pool[:max_concurrency] == 4
      assert config.image_pipe[:processing_pool] == config.pool[:name]
      assert config.telemetry == [level: :debug]

      assert error(fn -> Config.build!(Config.options!(%{"pool" => %{"max_queue" => 1}})) end) =~
               "pool"
    end

    test "builds validated mount options" do
      config =
        Config.build!(
          Config.options!(%{
            "processing" => %{"quality" => 70},
            "http" => %{"http_cache" => %{"mode" => "enabled"}, "allow_origin" => "*"}
          })
        )

      assert config.image_pipe[:quality] == 70
      assert config.image_pipe[:allow_origin] == "*"
      assert config.image_pipe[:http_cache][:mode] == :enabled
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

    test "takes the shutdown grace period from [server]" do
      config = Config.build!(Config.options!(%{"server" => %{"shutdown_timeout" => 30_000}}))
      assert config.server[:shutdown_timeout] == 30_000
    end

    test "warms the detector only when the build has it" do
      assert Config.build!([]).detector_warmup == nil

      available = ImagePipeServer.Test.AvailableDetector
      config = Config.build!(processing: [detector: available])
      assert config.detector_warmup == [detector: available]
    end

    test "rejects a required detector the build doesn't have" do
      assert error(fn ->
               Config.build!(Config.options!(%{"processing" => %{"detector_required" => true}}))
             end) =~ "processing.detector_required: the detector is not available in this build"
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
      assert config.image_pipe[:quality] == 75
    end
  end
end
