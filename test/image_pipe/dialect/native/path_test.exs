defmodule ImagePipe.Dialect.Native.PathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePipe.Dialect.Native.Path

  defp conn_for(path) do
    conn(:get, path)
  end

  # Plug.Test's conn/2 runs the path through URI.parse/1, which gives a
  # leading "//" authority semantics and treats a literal "?" as a query
  # delimiter — both wrong for exercising split_signature/1's and
  # extract/1's raw byte handling of pathological/garbage input. This sets
  # conn.request_path (and optionally query_string) directly, bypassing
  # URI parsing entirely.
  defp conn_with_raw_path(path, query \\ "") do
    conn(:get, "/")
    |> Map.put(:request_path, path)
    |> Map.put(:query_string, query)
  end

  defp with_script_name(conn, script_name) do
    %{conn | script_name: script_name}
  end

  # Percent-encodes every byte not permitted in an RFC 3986 path, leaving `/`
  # as source data — mirrors the client rule in [native §Sources].
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
      conn = conn_for("/w=800/src/images/cat.jpg")

      assert Path.split_signature(conn) == {nil, "/w=800/src/images/cat.jpg"}
    end

    test "extracts the sig value and returns the raw remainder" do
      conn = conn_for("/sig=AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM/w=800/src/x")

      assert Path.split_signature(conn) ==
               {"AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM", "/w=800/src/x"}
    end

    test "returns an empty signed_path when the sig segment is the entire path" do
      conn = conn_for("/sig=ABCDEF")

      assert Path.split_signature(conn) == {"ABCDEF", ""}
    end

    test "returns an empty sig value for a bare sig= segment" do
      conn = conn_for("/sig=/w=800")

      assert Path.split_signature(conn) == {"", "/w=800"}
    end

    test "never errors on duplicate slashes" do
      conn = conn_with_raw_path("//w=800/src/x")

      assert Path.split_signature(conn) == {nil, "//w=800/src/x"}
    end

    test "never errors on malformed percent escapes" do
      conn = conn_for("/src/%zz")

      assert Path.split_signature(conn) == {nil, "/src/%zz"}
    end

    test "never errors on dot segments" do
      conn = conn_for("/../w=800/src/x")

      assert Path.split_signature(conn) == {nil, "/../w=800/src/x"}
    end

    test "never errors on completely garbage paths" do
      conn = conn_with_raw_path("/%%%///???sig=not-really")

      assert Path.split_signature(conn) == {nil, "/%%%///???sig=not-really"}
    end

    test "a sig= segment that is not first is left untouched in signed_path" do
      conn = conn_for("/w=800/sig=ABC/src/x")

      assert Path.split_signature(conn) == {nil, "/w=800/sig=ABC/src/x"}
    end

    test "handles an empty mount-relative path" do
      conn =
        conn_for("/mount")
        |> with_script_name(["mount"])

      assert Path.split_signature(conn) == {nil, ""}
    end

    test "strips a multi-segment mount prefix as a raw string prefix" do
      conn =
        conn_for("/api/v2/w=800/src/x")
        |> with_script_name(["api", "v2"])

      assert Path.split_signature(conn) == {nil, "/w=800/src/x"}
    end

    test "raises when a script_name segment is not canonical unescaped ASCII" do
      conn =
        conn_for("/a%20b/w=800/src/x")
        |> with_script_name(["a b"])

      assert_raise ArgumentError, fn -> Path.split_signature(conn) end
    end

    test "raises when a script_name segment contains a percent sign" do
      conn =
        conn_for("/50%25/w=800/src/x")
        |> with_script_name(["50%"])

      assert_raise ArgumentError, fn -> Path.split_signature(conn) end
    end

    test "raises when request_path does not actually start with the reconstructed prefix" do
      conn =
        conn_for("/other/w=800/src/x")
        |> with_script_name(["mount"])

      assert_raise ArgumentError, fn -> Path.split_signature(conn) end
    end
  end

  describe "extract/1 happy paths" do
    test "lexes option segments and a src source, with byte-exact spans" do
      conn = conn_for("/w=800/src/images/cat.jpg")

      assert {:ok,
              %{
                segments: [{"w=800", {1, 5}}],
                source: {:src, "images/cat.jpg", {11, 14}}
              }} = Path.extract(conn)
    end

    test "lexes a src64 source" do
      encoded = Base.url_encode64("images/cat.jpg", padding: false)
      conn = conn_for("/w=800/src64/#{encoded}")

      assert {:ok,
              %{
                segments: [{"w=800", {1, 5}}],
                source: {:src64, "images/cat.jpg", {_offset, _len}}
              }} = Path.extract(conn)
    end

    test "skips a leading sig segment internally and never returns it" do
      conn = conn_for("/sig=AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM/w=800/src/x")

      assert {:ok, %{segments: [{"w=800", _span}], source: {:src, "x", _source_span}}} =
               Path.extract(conn)
    end

    test "spans are computed against the full mount-relative raw path, sig segment included" do
      conn = conn_for("/sig=ABCDEFG/w=800/src/x")

      assert {:ok, %{segments: [{"w=800", {13, 5}}], source: {:src, "x", {23, 1}}}} =
               Path.extract(conn)
    end

    test "strips the mount prefix before lexing" do
      conn =
        conn_for("/api/w=800/src/x")
        |> with_script_name(["api"])

      assert {:ok, %{segments: [{"w=800", {1, 5}}], source: {:src, "x", {11, 1}}}} =
               Path.extract(conn)
    end

    test "supports multiple option segments in original order" do
      conn = conn_for("/w=800/h=600/fit=cover/src/x")

      assert {:ok,
              %{
                segments: [{"w=800", _}, {"h=600", _}, {"fit=cover", _}],
                source: {:src, "x", _}
              }} = Path.extract(conn)
    end

    test "flag and then segments pass through as raw segments" do
      conn = conn_for("/extend/then/w=800/src/x")

      assert {:ok, %{segments: [{"extend", _}, {"then", _}, {"w=800", _}]}} = Path.extract(conn)
    end

    test "raises when a script_name segment is not canonical unescaped ASCII" do
      conn =
        conn_for("/a%20b/w=800/src/x")
        |> with_script_name(["a b"])

      assert_raise ArgumentError, fn -> Path.extract(conn) end
    end
  end

  describe "extract/1 rules" do
    test "a non-empty query string is an error" do
      conn = conn_for("/w=800/src/x?v=2")

      assert {:error, errors} = Path.extract(conn)
      assert Enum.any?(errors, &(&1.reason == :non_empty_query_string))
    end

    test "a sig= segment that is not first is an error" do
      conn = conn_for("/w=800/sig=ABC/src/x")

      assert {:error, errors} = Path.extract(conn)
      assert Enum.any?(errors, &(&1.reason == :sig_only_valid_first))
    end

    test "missing src/src64 marker entirely is an error" do
      conn = conn_for("/w=800/h=600")

      assert {:error, [%{reason: :missing_source_marker}]} = Path.extract(conn)
    end

    test "src with nothing after it (no trailing slash) is an error" do
      conn = conn_for("/w=800/src")

      assert {:error, [%{reason: :missing_source}]} = Path.extract(conn)
    end

    test "src with an empty tail (trailing slash, nothing after) is an error" do
      conn = conn_for("/w=800/src/")

      assert {:error, [%{reason: :missing_source}]} = Path.extract(conn)
    end

    test "src64 with nothing after it is an error" do
      conn = conn_for("/w=800/src64")

      assert {:error, [%{reason: :missing_source}]} = Path.extract(conn)
    end

    test "a malformed percent escape in the src tail is an error, never a source guess" do
      conn = conn_for("/src/%zz")

      assert {:error, [%{reason: :malformed_percent_escape}]} = Path.extract(conn)
    end

    test "a malformed percent escape at the end of the src tail is an error" do
      conn = conn_for("/src/abc%2")

      assert {:error, [%{reason: :malformed_percent_escape}]} = Path.extract(conn)
    end

    test "the src tail is percent-decoded exactly once" do
      # %2534 decodes once to "%34", NOT twice to "4"
      conn = conn_for("/src/%2534")

      assert {:ok, %{source: {:src, "%34", _span}}} = Path.extract(conn)
    end

    test "an embedded slash in a src64 tail is an error" do
      conn = conn_for("/src64/abc/def")

      assert {:error, [%{reason: :src64_embedded_slash}]} = Path.extract(conn)
    end

    test "padding in a src64 tail is an error" do
      encoded = Base.url_encode64("images/cat.jpg", padding: true)
      conn = conn_for("/src64/#{encoded}")

      assert {:error, [%{reason: :src64_padding}]} = Path.extract(conn)
    end

    test "an invalid base64 alphabet character in a src64 tail is an error" do
      conn = conn_for("/src64/not!valid")

      assert {:error, [%{reason: :invalid_base64}]} = Path.extract(conn)
    end

    test "a percent escape in an option segment is an error" do
      conn = conn_for("/w=%38%30%30/src/x")

      assert {:error, errors} = Path.extract(conn)
      assert Enum.any?(errors, &(&1.reason == :percent_in_option_segment))
    end

    test "an empty segment from duplicate slashes is an error" do
      conn = conn_for("/w=800//h=600/src/x")

      assert {:error, errors} = Path.extract(conn)
      assert Enum.any?(errors, &(&1.reason == :empty_segment))
    end

    test "a leading duplicate slash produces an empty segment error" do
      conn = conn_with_raw_path("//w=800/src/x")

      assert {:error, [%{reason: :empty_segment} | _]} = Path.extract(conn)
    end

    test "a single-dot segment is an error" do
      conn = conn_for("/./w=800/src/x")

      assert {:error, errors} = Path.extract(conn)
      assert Enum.any?(errors, &(&1.reason == :dot_segment))
    end

    test "a double-dot segment is an error" do
      conn = conn_for("/../w=800/src/x")

      assert {:error, errors} = Path.extract(conn)
      assert Enum.any?(errors, &(&1.reason == :dot_segment))
    end

    test "independent errors accumulate in one pass" do
      conn = conn_for("/w=%38%30%30/./sig=ABC/src/x")

      assert {:error, errors} = Path.extract(conn)
      reasons = Enum.map(errors, & &1.reason)

      assert :percent_in_option_segment in reasons
      assert :dot_segment in reasons
      assert :sig_only_valid_first in reasons
    end
  end

  describe "extract/1 span precision" do
    test "an unknown/invalid option segment's span covers just that segment" do
      conn = conn_for("/w=800/bogus%20value/src/x")

      assert {:error, [%{reason: :percent_in_option_segment, span: {7, 13}}]} =
               Path.extract(conn)
    end

    test "the missing-source-marker span points at the end of the path" do
      conn = conn_for("/w=800")

      assert {:error, [%{reason: :missing_source_marker, span: {6, 0}}]} = Path.extract(conn)
    end

    test "the non-empty-query-string span points at the end of the path" do
      conn = conn_for("/w=800/src/x?v=2")

      assert {:error, errors} = Path.extract(conn)
      assert %{reason: :non_empty_query_string, span: {12, 0}} = hd(errors)
    end
  end

  describe "extract/1 properties" do
    property "src percent-encode -> extract -> decode round-trips" do
      check all source <- StreamData.binary(min_length: 1, max_length: 64),
                max_runs: 100 do
        encoded = percent_encode_source(source)
        conn = conn_for("/src/#{encoded}")

        assert {:ok, %{source: {:src, ^source, _span}}} = Path.extract(conn)
      end
    end

    property "src64 base64url-encode -> extract -> decode round-trips" do
      check all source <- StreamData.binary(min_length: 1, max_length: 64),
                max_runs: 100 do
        encoded = Base.url_encode64(source, padding: false)
        conn = conn_for("/src64/#{encoded}")

        assert {:ok, %{source: {:src64, ^source, _span}}} = Path.extract(conn)
      end
    end
  end
end
