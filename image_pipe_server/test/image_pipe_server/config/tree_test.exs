defmodule ImagePipeServer.Config.TreeTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Config.Tree
  alias ImagePipeServer.ConfigError

  @moduletag :tmp_dir

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp read!(env, dir), do: Tree.read!(env, Path.join(dir, "absent.toml"))

  test "reads the file named by IPS_CONFIG", %{tmp_dir: dir} do
    path = write!(dir, "config.toml", ~s([processing]\nquality = 82\n))

    assert read!(%{"IPS_CONFIG" => path}, dir) == %{"processing" => %{"quality" => 82}}
  end

  test "an absent default file gives an empty tree", %{tmp_dir: dir} do
    assert read!(%{}, dir) == %{}
  end

  test "an absent IPS_CONFIG file is an error", %{tmp_dir: dir} do
    missing = Path.join(dir, "missing.toml")

    assert_raise ConfigError, ~r/IPS_CONFIG.*missing\.toml/, fn ->
      read!(%{"IPS_CONFIG" => missing}, dir)
    end
  end

  describe "invalid TOML" do
    defp toml_error(dir, contents) do
      path = write!(dir, "config.toml", contents)
      assert_raise(ConfigError, fn -> read!(%{"IPS_CONFIG" => path}, dir) end).message
    end

    test "names the file and position and redacts the value", %{tmp_dir: dir} do
      message = toml_error(dir, ~s([url]\nkeys = "sekrit\n))

      assert message =~ "config.toml on line 2, column 14"
      assert message =~ "    keys = <redacted value>\n           ^"
      refute message =~ "sekrit"
    end

    test "redacts an unquoted value the parser quotes back", %{tmp_dir: dir} do
      message = toml_error(dir, "keys = 0123abcd\n")

      assert message =~ "keys = <redacted value>"
      refute message =~ "0123abcd"
    end

    test "redacts lines without a key and tokens in the summary", %{tmp_dir: dir} do
      message = toml_error(dir, ~s(keys = [\n  "abc",\n  sekrit\n]\n))

      assert message =~ "invalid token <redacted value> in"
      assert message =~ "\n      <redacted value>\n"
      refute message =~ "sekrit"
    end

    test "redacts all of a line inside a multi-line string", %{tmp_dir: dir} do
      message = toml_error(dir, ~s(auth_token = """\nSEKRITAA=\\qSEKRITBB\n"""\n))

      assert message =~ "\n    <redacted value>\n"
      refute message =~ "SEKRIT"
    end

    test "redacts all of a line inside a multi-line array", %{tmp_dir: dir} do
      message = toml_error(dir, ~s(a = [\n  "x",\n  SEKRITAA=1\n]\n))

      assert message =~ "\n      <redacted value>\n"
      refute message =~ "SEKRIT"
    end

    test "redacts bytes the summary quotes", %{tmp_dir: dir} do
      message = toml_error(dir, ~s(token = "\\uD800"\n))

      assert message =~ "token = <redacted value>"
      refute message =~ "0x44"
    end

    test "keeps table headers", %{tmp_dir: dir} do
      assert toml_error(dir, "[sources.x\n") =~ "    [sources.x\n"
    end

    test "keeps key paths", %{tmp_dir: dir} do
      assert toml_error(dir, "a = 1\na = 2\n") =~ "cannot redefine key in path 'a'"
    end

    test "names the line of a byte that isn't UTF-8 and quotes nothing", %{tmp_dir: dir} do
      message = toml_error(dir, "port = 8080 # caf\xE9\n[url]\nkeys = [\"sekrit\"]\n")

      assert message =~ "config.toml is not valid UTF-8 on line 1"
      refute message =~ "sekrit"
      refute message =~ "115, 101, 107"
    end

    test "points at the start of a malformed table header", %{tmp_dir: dir} do
      for header <- ["[cache.output", "[serv#er]"] do
        message = toml_error(dir, "[server]\nport = 8080\n\n#{header}\nroot = \"/var/cache\"\n")

        assert message =~ ~r/\Ainvalid TOML: .* in .*config\.toml on line \d+, column \d+:/
        refute message =~ "/var/cache"
      end
    end

    test "reports a string the lexer can't finish as invalid TOML", %{tmp_dir: dir} do
      message = toml_error(dir, ~s(key = "\\u))

      assert message =~ ~r/\Ainvalid TOML/
    end

    test "reports a number the parser can't read as invalid TOML", %{tmp_dir: dir} do
      message = toml_error(dir, "port = 0xZZ\n")

      assert message =~ ~r/\Ainvalid TOML in .*config\.toml/
      refute message =~ "cannot read"
    end
  end

  @tag skip: System.cmd("id", ["-u"]) == {"0\n", 0} && "chmod doesn't stop root reading the file"
  test "an unreadable IPS_CONFIG file names the reason", %{tmp_dir: dir} do
    path = write!(dir, "config.toml", "")
    File.chmod!(path, 0o000)

    assert_raise ConfigError, ~r/cannot read .*config\.toml: permission denied/, fn ->
      read!(%{"IPS_CONFIG" => path}, dir)
    end
  end

  test "environment variables flatten the tree with __ between levels", %{tmp_dir: dir} do
    env = %{
      "IPS_SOURCES__TMDB__BASE_URL" => "https://example.com",
      "IPS_SOURCES__TMDB__MATCH__PREFIX" => "tmdb",
      "HOME" => "/home/app"
    }

    assert read!(env, dir) == %{
             "sources" => %{
               "tmdb" => %{
                 "base_url" => {:env, "https://example.com"},
                 "match" => %{"prefix" => {:env, "tmdb"}}
               }
             }
           }
  end

  test "an environment variable overrides the matching leaf in the file", %{tmp_dir: dir} do
    path = write!(dir, "config.toml", ~s([processing]\nquality = 82\nmax_input_pixels = 10\n))
    env = %{"IPS_CONFIG" => path, "IPS_PROCESSING__QUALITY" => "70"}

    assert read!(env, dir) == %{
             "processing" => %{"quality" => {:env, "70"}, "max_input_pixels" => 10}
           }
  end

  # Conversion decides whether it names a secret file or a `*_file` setting.
  test "a _FILE variable is kept as a reference without reading the file", %{tmp_dir: dir} do
    missing = Path.join(dir, "missing")

    assert read!(%{"IPS_URL__KEYS_FILE" => missing}, dir) == %{
             "url" => %{"keys" => {:env_file, "IPS_URL__KEYS_FILE", missing}}
           }
  end

  test "setting both a variable and its _FILE form is an error", %{tmp_dir: dir} do
    secret = write!(dir, "keys", "0123abcd")

    assert_raise ConfigError, ~r/IPS_URL__KEYS.*IPS_URL__KEYS_FILE/, fn ->
      read!(%{"IPS_URL__KEYS" => "a", "IPS_URL__KEYS_FILE" => secret}, dir)
    end
  end

  test "two variables that differ only in case are an error", %{tmp_dir: dir} do
    assert_raise ConfigError, ~r/both IPS_SERVER__PORT and IPS_Server__Port are set/, fn ->
      read!(%{"IPS_SERVER__PORT" => "1", "IPS_Server__Port" => "2"}, dir)
    end
  end

  test "a _FILE variable and a differently cased plain variable are an error", %{tmp_dir: dir} do
    assert_raise ConfigError, ~r/both IPS_URL__KEYS_FILE and IPS_url__keys are set/, fn ->
      read!(%{"IPS_url__keys" => "a", "IPS_URL__KEYS_FILE" => "/run/keys"}, dir)
    end
  end

  test "Kubernetes service-link variables are ignored", %{tmp_dir: dir} do
    env = %{
      "IPS_SERVICE_HOST" => "10.0.0.1",
      "IPS_SERVICE_PORT" => "8080",
      "IPS_SERVICE_PORT_HTTP" => "8080",
      "IPS_PORT" => "tcp://10.0.0.1:8080",
      "IPS_PORT_8080_TCP" => "tcp://10.0.0.1:8080",
      "IPS_PORT_8080_TCP_ADDR" => "10.0.0.1",
      "IPS_CACHE_PORT_6379_UDP_PROTO" => "udp",
      "IPS_PROCESSING__QUALITY" => "70"
    }

    assert read!(env, dir) == %{"processing" => %{"quality" => {:env, "70"}}}
  end

  test "a single-underscore variable is still read as a setting", %{tmp_dir: dir} do
    assert read!(%{"IPS_PROCESSING_QUALITY" => "70"}, dir) == %{
             "processing_quality" => {:env, "70"}
           }
  end

  test "a variable with an empty level is an error", %{tmp_dir: dir} do
    assert_raise ConfigError, ~r/IPS_URL____KEYS/, fn ->
      read!(%{"IPS_URL____KEYS" => "a"}, dir)
    end
  end

  test "a variable that sets a table and a value at once is an error", %{tmp_dir: dir} do
    assert_raise ConfigError, ~r/url\.keys/, fn ->
      read!(%{"IPS_URL__KEYS" => "a", "IPS_URL__KEYS__X" => "b"}, dir)
    end
  end
end
