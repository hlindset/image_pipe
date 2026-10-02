defmodule ImagePipeServer.Config.ReferenceTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Config.Reference

  @doc_path Path.expand("../../../docs/configuration.md", __DIR__)

  setup_all do
    %{reference: Reference.markdown()}
  end

  test "lists settings with their TOML types and defaults", %{reference: reference} do
    assert reference =~ "| `port` | integer ≥ 0 | `8080` |"
    assert reference =~ "| `quality` | integer > 0 | `80` |"

    assert reference =~
             ~s(| `format_quality` | table of integer > 0 | `{ avif = 63, webp = 79 }` |)

    assert reference =~
             ~s(| `http_cache` | `"validators"` or `"auto"` or `"public"` or `"private"` | `"validators"` |)

    assert reference =~ "| `keys` | array of string | `[]` |"
  end

  test "documents explicit conversions", %{reference: reference} do
    assert reference =~
             "| `source_encryption_keys` | array of string with a `base64:` or `hex:` prefix |"

    assert reference =~ "| `path_pattern` | string (regular expression) |"

    assert reference =~
             "| `cache_policy.freshness` | `\"origin\"` or `{ fallback = … }` or `{ force = … }`"

    assert reference =~ "| `jpeg_options.quant_table` | integer 0–8 |"
    assert reference =~ "| `png_options.bitdepth` | `1` or `2` or `4` or `8` or `16` |"
    assert reference =~ "| `output.max_size_bytes` | integer > 0 |"
  end

  test "documents mounts per adapter and S3 credentials", %{reference: reference} do
    assert reference =~ ~s(#### `adapter = "http"`)
    assert reference =~ "| `buckets` | table of the S3 settings above |"
    assert reference =~ "| `static.secret_access_key` | string |"
    assert reference =~ ~s(`provider = "assume_role"`)
  end

  test "names the settings only Elixir can set", %{reference: reference} do
    assert reference =~ "Elixir only: `telemetry_prefix`, `clock`"
    assert reference =~ "`req_options`"
  end

  test "docs/configuration.md holds the current reference", %{reference: reference} do
    assert Reference.extract(File.read!(@doc_path)) == reference,
           "run `mix image_pipe_server.gen.reference` to update docs/configuration.md"
  end
end
