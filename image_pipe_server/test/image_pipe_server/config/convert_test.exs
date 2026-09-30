defmodule ImagePipeServer.Config.ConvertTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Config.Convert
  alias ImagePipeServer.ConfigError

  defp convert(table, schema), do: Convert.options!(table, schema, ["section"])

  defp error(table, schema) do
    assert_raise(ConfigError, fn -> convert(table, schema) end).message
  end

  describe "scalars" do
    test "keep file values and parse environment strings" do
      schema = [
        name: [type: :string],
        quality: [type: :pos_integer],
        limit: [type: :non_neg_integer],
        strip: [type: :boolean],
        ratio: [type: :float]
      ]

      file = %{"name" => "a", "quality" => 82, "limit" => 0, "strip" => false, "ratio" => 0.5}

      env = %{
        "name" => {:env, "a"},
        "quality" => {:env, "82"},
        "limit" => {:env, "0"},
        "strip" => {:env, "false"},
        "ratio" => {:env, "0.5"}
      }

      expected = [limit: 0, name: "a", quality: 82, ratio: 0.5, strip: false]
      assert Enum.sort(convert(file, schema)) == expected
      assert Enum.sort(convert(env, schema)) == expected
    end

    test "a file integer converts to a float" do
      assert convert(%{"ratio" => 1}, ratio: [type: :float]) == [ratio: 1.0]
    end

    test "a file string is not parsed as a number" do
      assert error(%{"quality" => "82"}, quality: [type: :pos_integer]) =~
               "section.quality: expected an integer"
    end

    test "an unparsable environment value names the setting, not the value" do
      message = error(%{"quality" => {:env, "high-secret"}}, quality: [type: :integer])

      assert message =~ "section.quality"
      refute message =~ "high-secret"
    end
  end

  describe "enumerations" do
    test "convert names to atoms" do
      schema = [stable: [type: {:in, [:auto, :trusted]}]]

      assert convert(%{"stable" => "trusted"}, schema) == [stable: :trusted]
      assert convert(%{"stable" => {:env, "auto"}}, schema) == [stable: :auto]
      assert error(%{"stable" => "sometimes"}, schema) =~ "expected one of auto, trusted"
    end

    test "accept integers in a range" do
      schema = [quant_table: [type: {:in, 0..8}]]

      assert convert(%{"quant_table" => 3}, schema) == [quant_table: 3]
      assert convert(%{"quant_table" => {:env, "3"}}, schema) == [quant_table: 3]
      assert error(%{"quant_table" => 9}, schema) =~ "section.quant_table"
    end
  end

  describe "lists" do
    test "convert each element; the environment separates elements with commas" do
      schema = [keys: [type: {:list, :string}], sizes: [type: {:list, :pos_integer}]]

      assert Enum.sort(convert(%{"keys" => ["a", "b"], "sizes" => [1]}, schema)) ==
               [keys: ["a", "b"], sizes: [1]]

      assert Enum.sort(convert(%{"keys" => {:env, "a, b"}, "sizes" => {:env, "1,2"}}, schema)) ==
               [keys: ["a", "b"], sizes: [1, 2]]
    end

    test "name the failing element" do
      assert error(%{"sizes" => [1, "x"]}, sizes: [type: {:list, :pos_integer}]) =~
               "section.sizes[1]: expected an integer"
    end
  end

  describe "tables" do
    test "convert keyword lists with known keys" do
      schema = [http_cache: [type: :keyword_list, keys: [mode: [type: {:in, [:enabled]}]]]]

      assert convert(%{"http_cache" => %{"mode" => "enabled"}}, schema) ==
               [http_cache: [mode: :enabled]]
    end

    test "convert maps with atom keys" do
      schema = [format_quality: [type: {:map, :atom, :pos_integer}]]

      assert convert(%{"format_quality" => %{"webp" => 80}}, schema) ==
               [format_quality: %{webp: 80}]
    end

    test "reject atom keys that name nothing the library knows" do
      schema = [format_quality: [type: {:map, :atom, :pos_integer}]]

      assert error(%{"format_quality" => %{"no_such_format_zzz" => 80}}, schema) =~
               "section.format_quality.no_such_format_zzz: unknown key"
    end

    test "convert maps with string keys" do
      schema = [buckets: [type: {:map, :string, :string}]]

      assert convert(%{"buckets" => %{"a" => "b"}}, schema) == [buckets: %{"a" => "b"}]
    end

    test "convert a single-entry table to a tagged tuple" do
      schema = [
        freshness: [
          type:
            {:or, [{:in, [:origin]}, {:tuple, [{:in, [:fallback, :force]}, :non_neg_integer]}]}
        ]
      ]

      assert convert(%{"freshness" => "origin"}, schema) == [freshness: :origin]
      assert convert(%{"freshness" => %{"force" => 60}}, schema) == [freshness: {:force, 60}]

      assert convert(%{"freshness" => %{"fallback" => {:env, "5"}}}, schema) ==
               [freshness: {:fallback, 5}]

      assert error(%{"freshness" => %{"force" => "x"}}, schema) =~
               "section.freshness.force: expected an integer"
    end
  end

  describe "alternatives" do
    test "take the first alternative that converts" do
      schema = [max_body_bytes: [type: {:or, [nil, :non_neg_integer]}]]

      assert convert(%{"max_body_bytes" => {:env, "10"}}, schema) == [max_body_bytes: 10]
    end
  end

  describe "types the file cannot express" do
    test "pass scalars through to custom validators" do
      schema = [root: [type: {:custom, __MODULE__, :validate, []}]]

      assert convert(%{"root" => "/data"}, schema) == [root: "/data"]
      assert convert(%{"root" => {:env, "/data"}}, schema) == [root: "/data"]
    end

    test "reject functions, modules, and untyped settings" do
      schema = [
        clock: [type: {:custom, __MODULE__, :validate, []}],
        resolver: [type: {:fun, 1}],
        pool: [type: {:or, [:atom, :pid]}],
        anything: [type: :any]
      ]

      for key <- ["resolver", "pool", "anything"] do
        assert error(%{key => "x"}, schema) =~
                 "section.#{key}: not supported in the configuration file"
      end

      assert error(%{"clock" => %{"a" => 1}}, schema) =~
               "section.clock: not supported in the configuration file"
    end
  end

  test "unknown settings are errors" do
    assert error(%{"qualty" => 80}, quality: [type: :pos_integer]) =~
             "section.qualty: unknown setting"
  end

  test "explicit conversions receive the value and its path" do
    schema = [
      pattern: [
        type:
          {:convert,
           fn value, path ->
             with {:ok, source} <- Convert.string(value, path), do: Regex.compile(source)
           end}
      ]
    ]

    assert [pattern: %Regex{source: "a+"}] = convert(%{"pattern" => "a+"}, schema)
    assert [pattern: %Regex{source: "a+"}] = convert(%{"pattern" => {:env, "a+"}}, schema)
  end
end
