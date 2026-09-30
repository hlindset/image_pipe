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

    test "keeps table headers", %{tmp_dir: dir} do
      assert toml_error(dir, "[sources.x\n") =~ "    [sources.x\n"
    end

    test "keeps key paths", %{tmp_dir: dir} do
      assert toml_error(dir, "a = 1\na = 2\n") =~ "cannot redefine key in path 'a'"
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

  test "a _FILE variable reads the value from that file", %{tmp_dir: dir} do
    secret = write!(dir, "keys", "0123abcd\n")

    assert read!(%{"IPS_URL__KEYS_FILE" => secret}, dir) == %{
             "url" => %{"keys" => {:env, "0123abcd"}}
           }
  end

  test "setting both a variable and its _FILE form is an error", %{tmp_dir: dir} do
    secret = write!(dir, "keys", "0123abcd")

    assert_raise ConfigError, ~r/IPS_URL__KEYS.*IPS_URL__KEYS_FILE/, fn ->
      read!(%{"IPS_URL__KEYS" => "a", "IPS_URL__KEYS_FILE" => secret}, dir)
    end
  end

  test "an unreadable _FILE is an error naming the variable", %{tmp_dir: dir} do
    assert_raise ConfigError, ~r/IPS_URL__KEYS_FILE/, fn ->
      read!(%{"IPS_URL__KEYS_FILE" => Path.join(dir, "missing")}, dir)
    end
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
