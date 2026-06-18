defmodule ImagePipe.Test.ImgproxyDifferential.ManifestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ImagePipe.Test.ImgproxyDifferential.Manifest

  @sample %{
    imgproxy_digest: "sha256:abc",
    imgproxy_libvips: "8.18.2",
    pipe_libvips_at_gen: "8.18.2",
    sources: %{"high_freq.jpg" => "deadbeef"},
    entries: %{
      "rs_fill" => %{
        kind: :transform,
        authored_sha256: "aaa",
        fixture_filename: "rs_fill.png",
        fixture_sha256: "bbb"
      },
      "lossy_webp" => %{
        kind: :lossy,
        authored_sha256: "ccc",
        width: 240,
        height: 180,
        content_type: "image/webp"
      }
    }
  }

  test "round-trips through encode/decode", %{tmp_dir: tmp} do
    path = Path.join(tmp, "manifest.exs")
    Manifest.write!(path, @sample)
    assert Manifest.load!(path) == @sample
  end

  test "write! emits inner entry-map keys in canonical sorted order", %{tmp_dir: tmp} do
    path = Path.join(tmp, "manifest.exs")
    Manifest.write!(path, @sample)
    rendered = File.read!(path)

    assert key_order(rendered, "rs_fill") ==
             ~w(kind authored_sha256 fixture_filename fixture_sha256)a |> Enum.sort()

    assert key_order(rendered, "lossy_webp") ==
             ~w(kind authored_sha256 width height content_type)a |> Enum.sort()
  end

  # The order the keys of `entry_id`'s inner map appear in the rendered manifest.
  # Parse the emitted source as AST (map pairs keep their source order) rather than
  # scraping text, so nested maps and value contents can't perturb the reading.
  defp key_order(rendered, entry_id) do
    {:%{}, _, top} = Code.string_to_quoted!(rendered)
    {:%{}, _, entries} = Keyword.fetch!(top, :entries)
    {^entry_id, {:%{}, _, inner}} = Enum.find(entries, fn {id, _} -> id == entry_id end)
    Keyword.keys(inner)
  end

  test "load! rejects a malformed manifest with a clear error", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bad.exs")
    File.write!(path, "%{not: :a_manifest}")
    assert_raise RuntimeError, ~r/invalid manifest/i, fn -> Manifest.load!(path) end
  end

  test "authored_sha256 is stable and order-independent over authored fields" do
    a = %{
      source: :high_freq,
      opts: "rs:fill:240:180",
      verdict: :equal,
      group: :transform,
      tol: nil,
      divergence: nil
    }

    b = %{
      group: :transform,
      verdict: :equal,
      opts: "rs:fill:240:180",
      source: :high_freq,
      divergence: nil,
      tol: nil
    }

    assert Manifest.authored_sha256(a) == Manifest.authored_sha256(b)
  end

  test "authored_sha256 is stable for a nested :divergence map regardless of key order" do
    a = %{
      source: :icc_p3,
      opts: "rs:fit:200:200/scp:0",
      verdict: :diverges,
      group: :transform,
      tol: nil,
      divergence: %{
        reason: "accepted resampling divergence",
        max_delta: 60..160,
        outliers: 3_000..4_600,
        issue: 124
      }
    }

    b = %{
      a
      | divergence: %{
          issue: 124,
          outliers: 3_000..4_600,
          max_delta: 60..160,
          reason: "accepted resampling divergence"
        }
    }

    assert Manifest.authored_sha256(a) == Manifest.authored_sha256(b)
  end

  test "authored_sha256 changes when an authored field changes" do
    a = %{
      source: :high_freq,
      opts: "rs:fill:240:180",
      verdict: :equal,
      group: :transform,
      tol: nil,
      divergence: nil
    }

    b = %{a | verdict: :diverges}
    refute Manifest.authored_sha256(a) == Manifest.authored_sha256(b)
  end

  test "file_sha256 hashes file bytes", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bytes.bin")
    File.write!(path, "hello")
    expected = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    assert Manifest.file_sha256(path) == expected
  end
end
