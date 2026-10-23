defmodule ImagePipeServer.Config.ReferenceTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Config.Reference

  @doc_path Path.expand("../../../docs/server-configuration.md", __DIR__)

  setup_all do
    %{reference: Reference.markdown()}
  end

  test "lists settings with their TOML types and defaults", %{reference: reference} do
    assert reference =~ "| `port` | integer 0–65535 | `8080` |"
    assert reference =~ "| `quality` | integer 1–100 | `80` |"

    assert reference =~
             ~s(| `format_quality` | table of integer > 0 | `{ avif = 56, webp = 79 }` |)

    assert reference =~
             ~s(| `http_cache` | `"validators"` or `"auto"` or `"public"` or `"private"` | `"validators"` |)

    assert reference =~ "| `keys` | array of hex strings, each at least 64 digits | `[]` |"
  end

  test "shows defaults the library applies outside the schema", %{reference: reference} do
    assert reference =~
             ~s(| `format_order` | array of `"avif"` or `"webp"` | `["avif", "webp"]` |)

    assert reference =~ "| `webp_options.effort` | integer 0–6 | `4` |"
    assert reference =~ "| `avif_options.effort` | integer 0–9 | `3` |"

    assert reference =~
             ~s(| `avif_options.subsample_mode` | `"auto"` or `"on"` or `"off"` | `"off"` |)

    assert reference =~
             "| `svg.max_render_pixels` | integer > 0 | four times `max_input_pixels` |"

    assert reference =~ "| `address_policy.allow_private` | boolean | `false` |"
  end

  test "documents explicit conversions", %{reference: reference} do
    assert reference =~
             "| `source_encryption_keys` | array of hex strings, each a 32-byte key | `[]` |"

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

  test "marks required settings", %{reference: reference} do
    assert reference =~ ~s(| `adapter` | `"file"` or `"http"` or `"s3"` | required |)
    assert reference =~ "| `endpoint` | string | required |"
    assert reference =~ "| `output.root` | string (absolute path) | required |"
    assert reference =~ "| `static.access_key_id` | string | required |"
    assert reference =~ "| `token_file` | string |  |"
  end

  test "names the settings only Elixir can set", %{reference: reference} do
    assert reference =~
             "Elixir only: `preset_lookup`, `telemetry_prefix`, `clock`"

    assert reference =~ "`req_options`"
  end

  test "docs/server-configuration.md holds the current reference", %{reference: reference} do
    assert Reference.extract(File.read!(@doc_path)) == reference,
           "run `mix image_pipe_server.gen.reference` to update docs/server-configuration.md"
  end
end
