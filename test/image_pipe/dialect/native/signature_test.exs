defmodule ImagePipe.Dialect.Native.SignatureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.Native.Signature

  @key_a "00112233445566778899aabbccddeeff00112233445566778899aabbccddee"
  @key_b "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"

  defp config(keys), do: [keys: keys]

  describe "verify/3 — no keys configured" do
    test "no sig segment → {:ok, nil} (legitimately unsigned)" do
      assert Signature.verify(nil, "/w=800/src/x", config([])) == {:ok, nil}
    end

    test "sig segment present → :signature_without_keys, even if it decodes fine" do
      sig = Signature.sign("/w=800/src/x", config([@key_a]))

      assert Signature.verify(sig, "/w=800/src/x", config([])) ==
               {:error, :signature_without_keys}
    end

    test "empty sig= segment (bare `sig=`) with no keys → :signature_without_keys" do
      assert Signature.verify("", "/w=800/src/x", config([])) ==
               {:error, :signature_without_keys}
    end
  end

  describe "verify/3 — keys configured" do
    test "missing sig segment → :missing_signature" do
      assert Signature.verify(nil, "/w=800/src/x", config([@key_a])) ==
               {:error, :missing_signature}
    end

    test "empty sig= segment → :invalid_signature (not :missing_signature)" do
      assert Signature.verify("", "/w=800/src/x", config([@key_a])) ==
               {:error, :invalid_signature}
    end

    test "valid signature with the first key → {:ok, 0}" do
      signed_path = "/w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_a]))

      assert Signature.verify(sig, signed_path, config([@key_a])) == {:ok, 0}
    end

    test "valid signature matching the second key in an ordered list → {:ok, 1}" do
      signed_path = "/w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_b]))

      assert Signature.verify(sig, signed_path, config([@key_a, @key_b])) == {:ok, 1}
    end

    test "sign/2 always uses the first key" do
      signed_path = "/w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_a, @key_b]))

      assert Signature.verify(sig, signed_path, config([@key_a, @key_b])) == {:ok, 0}
    end

    test "wrong key → :invalid_signature" do
      signed_path = "/w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_b]))

      assert Signature.verify(sig, signed_path, config([@key_a])) == {:error, :invalid_signature}
    end

    test "tampered signed_path → :invalid_signature" do
      sig = Signature.sign("/w=800/src/x", config([@key_a]))

      assert Signature.verify(sig, "/w=801/src/x", config([@key_a])) ==
               {:error, :invalid_signature}
    end

    test "garbage non-base64 signature → :invalid_signature" do
      # 43 chars but contains characters outside the url-safe base64 alphabet
      garbage = String.duplicate("!", 43)

      assert Signature.verify(garbage, "/w=800/src/x", config([@key_a])) ==
               {:error, :invalid_signature}
    end
  end

  describe "verify/3 — canonical signature encoding" do
    test "a signature shorter than 43 chars is rejected" do
      signed_path = "/w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_a]))
      short = binary_part(sig, 0, 42)

      assert Signature.verify(short, signed_path, config([@key_a])) ==
               {:error, :invalid_signature}
    end

    test "a signature longer than 43 chars is rejected" do
      signed_path = "/w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_a]))
      long = sig <> "A"

      assert Signature.verify(long, signed_path, config([@key_a])) ==
               {:error, :invalid_signature}
    end

    test "a padded (non-canonical) signature is rejected even if bytes match" do
      signed_path = "/w=800/src/x"
      key = Base.decode16!(@key_a, case: :mixed)
      mac = :crypto.mac(:hmac, :sha256, key, signed_path)
      padded = Base.url_encode64(mac, padding: true)

      # sanity: padded form is 44 chars (one "=" pad char) — a different
      # spelling of the same 43-char canonical signature.
      assert byte_size(padded) == 44
      assert String.ends_with?(padded, "=")

      assert Signature.verify(padded, signed_path, config([@key_a])) ==
               {:error, :invalid_signature}
    end

    test "a valid canonical signature is exactly 43 characters" do
      sig = Signature.sign("/w=800/src/x", config([@key_a]))

      assert byte_size(sig) == 43
      refute String.contains?(sig, "=")
    end
  end

  describe "verify/3 — ordering: raw bytes, no normalization" do
    test "a signed path containing a duplicate slash verifies against the raw bytes as sent" do
      # The MAC covers signed_path exactly as split_signature/1 returns it —
      # duplicate slashes are signature-significant, not normalized away.
      # Parsing would later 400 on the empty segment; that is out of scope
      # for this module (verify operates purely on raw bytes).
      signed_path = "//w=800/src/x"
      sig = Signature.sign(signed_path, config([@key_a]))

      assert Signature.verify(sig, signed_path, config([@key_a])) == {:ok, 0}
    end
  end

  describe "sign/2 → verify/3 round-trip property" do
    property "any generated option path signs and verifies with the first configured key" do
      check all(
              path <- option_path_generator(),
              max_runs: 50
            ) do
        sig = Signature.sign(path, config([@key_a, @key_b]))

        assert Signature.verify(sig, path, config([@key_a, @key_b])) == {:ok, 0}
      end
    end

    defp option_path_generator do
      segment =
        StreamData.string(?a..?z, min_length: 1, max_length: 6)
        |> StreamData.map(&"w=#{&1}")

      {StreamData.list_of(segment, max_length: 5),
       StreamData.string(?a..?z, min_length: 1, max_length: 10)}
      |> StreamData.bind(fn {segments, source} ->
        StreamData.constant("/" <> Enum.join(segments ++ ["src", source], "/"))
      end)
    end
  end

  describe "expired?/2 — the `expires` gate" do
    test "no expires configured (nil) → never expired" do
      refute Signature.expired?(nil, 1_000)
    end

    test "expires in the future → not expired" do
      refute Signature.expired?(2_000, 1_000)
    end

    test "expires exactly equal to now → not expired (still valid at the boundary)" do
      refute Signature.expired?(1_000, 1_000)
    end

    test "expires in the past → expired" do
      assert Signature.expired?(999, 1_000)
    end
  end
end
