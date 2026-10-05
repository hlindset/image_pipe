defmodule ImagePipe.API.PathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.API.Path

  # Percent-encodes every byte not permitted in an RFC 3986 path, leaving `/`
  # as source data — mirrors the client rule in [API §Sources].
  defp percent_encode_source(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map_join(&encode_source_byte/1)
  end

  defp encode_source_byte(byte)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9,
       do: <<byte>>

  defp encode_source_byte(byte) when byte in [?-, ?., ?_, ?~, ?/], do: <<byte>>

  defp encode_source_byte(byte) do
    hex =
      byte
      |> Integer.to_string(16)
      |> String.upcase()
      |> String.pad_leading(2, "0")

    "%" <> hex
  end

  describe "split_signature/1" do
    test "returns {nil, path} when there is no sig segment" do
      path = "/w=800/src/images/cat.jpg"

      assert Path.split_signature(path) == {nil, "/w=800/src/images/cat.jpg"}
    end

    test "extracts the sig value and returns the raw remainder" do
      path = "/sig=AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM/w=800/src/x"

      assert Path.split_signature(path) ==
               {"AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM", "/w=800/src/x"}
    end

    test "returns an empty signed_path when the sig segment is the entire path" do
      path = "/sig=ABCDEF"

      assert Path.split_signature(path) == {"ABCDEF", ""}
    end

    test "returns an empty sig value for a bare sig= segment" do
      path = "/sig=/w=800"

      assert Path.split_signature(path) == {"", "/w=800"}
    end

    test "never errors on duplicate slashes" do
      path = "//w=800/src/x"

      assert Path.split_signature(path) == {nil, "//w=800/src/x"}
    end

    test "never errors on malformed percent escapes" do
      path = "/src/%zz"

      assert Path.split_signature(path) == {nil, "/src/%zz"}
    end

    test "never errors on dot segments" do
      path = "/../w=800/src/x"

      assert Path.split_signature(path) == {nil, "/../w=800/src/x"}
    end

    test "never errors on completely garbage paths" do
      path = "/%%%///???sig=not-really"

      assert Path.split_signature(path) == {nil, "/%%%///???sig=not-really"}
    end

    test "a sig= segment that is not first is left untouched in signed_path" do
      path = "/w=800/sig=ABC/src/x"

      assert Path.split_signature(path) == {nil, "/w=800/sig=ABC/src/x"}
    end

    test "handles an empty mount-relative path" do
      assert Path.split_signature("") == {nil, ""}
    end
  end

  describe "extract/2 happy paths" do
    test "lexes option segments and a src source, with byte-exact spans" do
      path = "/w=800/src/images/cat.jpg"

      assert {:ok,
              %{
                segments: [{"w=800", {1, 5}}],
                source: {:src, "images/cat.jpg", {11, 14}}
              }} = Path.extract(path, "")
    end

    test "lexes a src64 source" do
      encoded = Base.url_encode64("images/cat.jpg", padding: false)
      path = "/w=800/src64/#{encoded}"

      assert {:ok,
              %{
                segments: [{"w=800", {1, 5}}],
                source: {:src64, "images/cat.jpg", {_offset, _len}}
              }} = Path.extract(path, "")
    end

    test "skips a leading sig segment internally and never returns it" do
      path = "/sig=AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM/w=800/src/x"

      assert {:ok, %{segments: [{"w=800", _span}], source: {:src, "x", _source_span}}} =
               Path.extract(path, "")
    end

    test "lexes an encrypted source token without decoding it" do
      path = "/w=800/enc/AQAB-c_d"

      assert {:ok,
              %{
                segments: [{"w=800", {1, 5}}],
                source: {:enc, "AQAB-c_d", {11, 8}}
              }} = Path.extract(path, "")
    end

    test "leaves malformed encrypted token shapes for the fixed concealment failure" do
      assert {:ok, %{source: {:enc, "", {4, 0}}}} = Path.extract("/enc", "")
      assert {:ok, %{source: {:enc, "", {5, 0}}}} = Path.extract("/enc/", "")

      assert {:ok, %{source: {:enc, "bad/token", {5, 9}}}} =
               Path.extract("/enc/bad/token", "")
    end

    test "spans are computed against the full mount-relative raw path, sig segment included" do
      path = "/sig=ABCDEFG/w=800/src/x"

      assert {:ok, %{segments: [{"w=800", {13, 5}}], source: {:src, "x", {23, 1}}}} =
               Path.extract(path, "")
    end

    test "supports multiple option segments in original order" do
      path = "/w=800/h=600/fit=cover/src/x"

      assert {:ok,
              %{
                segments: [{"w=800", _}, {"h=600", _}, {"fit=cover", _}],
                source: {:src, "x", _}
              }} = Path.extract(path, "")
    end

    test "flag and separator segments pass through as raw segments" do
      path = "/extend/-/w=800/src/x"

      assert {:ok, %{segments: [{"extend", _}, {"-", _}, {"w=800", _}]}} = Path.extract(path, "")
    end
  end

  describe "diagnostic_path/1" do
    test "masks an encrypted token without changing diagnostic byte offsets" do
      raw_path = "/sig=ABC/w=bad/enc/private/token"
      redacted = Path.diagnostic_path(raw_path)

      assert redacted == "/sig=***/w=bad/enc/*************"
      assert byte_size(redacted) == byte_size(raw_path)
      refute redacted =~ "ABC"
      refute redacted =~ "private"
      refute redacted =~ "token"
    end

    test "masks a leading signature on ordinary-source diagnostics" do
      raw_path = "/sig=private-signature/w=bad/src/images/cat.jpg"
      redacted = Path.diagnostic_path(raw_path)

      assert byte_size(redacted) == byte_size(raw_path)
      refute redacted =~ "private-signature"
      assert redacted =~ "/w=bad/src/images/cat.jpg"
    end

    test "masks a misplaced signature segment before the source marker" do
      raw_path = "/w=bad/sig=private-signature/src/images/cat.jpg"
      redacted = Path.diagnostic_path(raw_path)

      assert byte_size(redacted) == byte_size(raw_path)
      refute redacted =~ "private-signature"
      assert redacted =~ "/w=bad/sig=*****************/src/images/cat.jpg"
    end

    test "does not treat enc text inside an ordinary source as a concealed token" do
      raw_path = "/w=bad/src/images/enc/private.jpg"
      assert Path.diagnostic_path(raw_path) == raw_path
    end
  end

  describe "extract/2 rules" do
    test "a non-empty query string is an error" do
      path = "/w=800/src/x"

      assert {:error, errors} = Path.extract(path, "v=2")
      assert Enum.any?(errors, &(&1.reason == :non_empty_query_string))
    end

    test "a sig= segment that is not first is an error" do
      path = "/w=800/sig=ABC/src/x"

      assert {:error, errors} = Path.extract(path, "")
      assert Enum.any?(errors, &(&1.reason == :sig_only_valid_first))
    end

    test "missing a source marker entirely is an error" do
      path = "/w=800/h=600"

      assert {:error, [%{reason: :missing_source_marker}]} = Path.extract(path, "")
    end

    test "src with nothing after it (no trailing slash) is an error" do
      path = "/w=800/src"

      assert {:error, [%{reason: :missing_source}]} = Path.extract(path, "")
    end

    test "src with an empty tail (trailing slash, nothing after) is an error" do
      path = "/w=800/src/"

      assert {:error, [%{reason: :missing_source}]} = Path.extract(path, "")
    end

    test "src64 with nothing after it is an error" do
      path = "/w=800/src64"

      assert {:error, [%{reason: :missing_source}]} = Path.extract(path, "")
    end

    test "a malformed percent escape in the src tail is an error, never a source guess" do
      path = "/src/%zz"

      assert {:error, [%{reason: :malformed_percent_escape}]} = Path.extract(path, "")
    end

    test "a malformed percent escape at the end of the src tail is an error" do
      path = "/src/abc%2"

      assert {:error, [%{reason: :malformed_percent_escape}]} = Path.extract(path, "")
    end

    test "the src tail is percent-decoded exactly once" do
      # %2534 decodes once to "%34", NOT twice to "4"
      path = "/src/%2534"

      assert {:ok, %{source: {:src, "%34", _span}}} = Path.extract(path, "")
    end

    test "an embedded slash in a src64 tail is an error" do
      path = "/src64/abc/def"

      assert {:error, [%{reason: :src64_embedded_slash}]} = Path.extract(path, "")
    end

    test "padding in a src64 tail is an error" do
      encoded = Base.url_encode64("images/cat.jpg", padding: true)
      path = "/src64/#{encoded}"

      assert {:error, [%{reason: :src64_padding}]} = Path.extract(path, "")
    end

    test "an invalid base64 alphabet character in a src64 tail is an error" do
      path = "/src64/not!valid"

      assert {:error, [%{reason: :invalid_base64}]} = Path.extract(path, "")
    end

    test "a percent escape in an option segment is an error" do
      path = "/w=%38%30%30/src/x"

      assert {:error, errors} = Path.extract(path, "")
      assert Enum.any?(errors, &(&1.reason == :percent_in_option_segment))
    end

    test "an empty segment from duplicate slashes is an error" do
      path = "/w=800//h=600/src/x"

      assert {:error, errors} = Path.extract(path, "")
      assert Enum.any?(errors, &(&1.reason == :empty_segment))
    end

    test "a leading duplicate slash produces an empty segment error" do
      path = "//w=800/src/x"

      assert {:error, [%{reason: :empty_segment} | _]} = Path.extract(path, "")
    end

    test "a single-dot segment is an error" do
      path = "/./w=800/src/x"

      assert {:error, errors} = Path.extract(path, "")
      assert Enum.any?(errors, &(&1.reason == :dot_segment))
    end

    test "a double-dot segment is an error" do
      path = "/../w=800/src/x"

      assert {:error, errors} = Path.extract(path, "")
      assert Enum.any?(errors, &(&1.reason == :dot_segment))
    end

    test "independent errors accumulate in one pass" do
      path = "/w=%38%30%30/./sig=ABC/src/x"

      assert {:error, errors} = Path.extract(path, "")
      reasons = Enum.map(errors, & &1.reason)

      assert :percent_in_option_segment in reasons
      assert :dot_segment in reasons
      assert :sig_only_valid_first in reasons
    end
  end

  describe "extract/2 span precision" do
    test "an unknown/invalid option segment's span covers just that segment" do
      path = "/w=800/bogus%20value/src/x"

      assert {:error, [%{reason: :percent_in_option_segment, spans: [{7, 13}]}]} =
               Path.extract(path, "")
    end

    test "the missing-source-marker span points at the end of the path" do
      path = "/w=800"

      assert {:error, [%{reason: :missing_source_marker, spans: [{6, 0}]}]} =
               Path.extract(path, "")
    end

    test "the non-empty-query-string span points at the end of the path" do
      path = "/w=800/src/x"

      assert {:error, errors} = Path.extract(path, "v=2")
      assert %{reason: :non_empty_query_string, spans: [{12, 0}]} = hd(errors)
    end
  end

  describe "extract/2 properties" do
    property "src percent-encode -> extract -> decode round-trips" do
      check all source <- StreamData.binary(min_length: 1, max_length: 64),
                max_runs: 100 do
        encoded = percent_encode_source(source)
        path = "/src/#{encoded}"

        assert {:ok, %{source: {:src, ^source, _span}}} = Path.extract(path, "")
      end
    end

    property "src64 base64url-encode -> extract -> decode round-trips" do
      check all source <- StreamData.binary(min_length: 1, max_length: 64),
                max_runs: 100 do
        encoded = Base.url_encode64(source, padding: false)
        path = "/src64/#{encoded}"

        assert {:ok, %{source: {:src64, ^source, _span}}} = Path.extract(path, "")
      end
    end
  end

  # The pattern the scan replaced, kept as the reference.
  @malformed_percent ~r/%($|[^0-9A-Fa-f]|[0-9A-Fa-f]$|[0-9A-Fa-f][^0-9A-Fa-f])/

  property "a src tail is rejected exactly when it has a malformed percent escape" do
    check all tail <- percent_bytes(), max_runs: 500 do
      malformed? =
        match?(
          {:error, [%{reason: :malformed_percent_escape}]},
          Path.extract("/src/x" <> tail, "")
        )

      assert malformed? == Regex.match?(@malformed_percent, tail)
    end
  end

  defp percent_bytes do
    ["%", "a", "F", "0", "9", "g", "z", ".", "\n", "%2", "%41"]
    |> Enum.map(&constant/1)
    |> one_of()
    |> list_of(max_length: 10)
    |> map(&Enum.join/1)
  end
end
