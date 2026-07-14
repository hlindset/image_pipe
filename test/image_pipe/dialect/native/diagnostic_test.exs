defmodule ImagePipe.Dialect.Native.DiagnosticTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Native.Diagnostic
  alias ImagePipe.Dialect.Native.DiagnosticRenderer
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Dialect.Native.Path

  defp conn_for(path) do
    conn(:get, path)
  end

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp parse(segments) do
    Parser.parse(lexed(segments), [])
  end

  defp fragment(string), do: Parser.parse_option_fragment(string, [])

  # -- migration: Path.extract/1 emits %Diagnostic{} structs -------------

  describe "Path.extract/1 emits %Diagnostic{} structs" do
    test "every error is a %Diagnostic{} with a non-empty message and a non-empty spans list" do
      conn = conn_for("/w=%38%30%30/./sig=ABC/src/x")

      assert {:error, diagnostics} = Path.extract(conn)
      assert diagnostics != []

      for diagnostic <- diagnostics do
        assert %Diagnostic{reason: reason, message: message, spans: spans} = diagnostic
        assert is_atom(reason)
        assert is_binary(message) and message != ""
        assert is_list(spans) and spans != []
      end
    end

    @path_reasons [
      {"/w=800/src/x?v=2", :non_empty_query_string},
      {"/w=800/sig=ABC/src/x", :sig_only_valid_first},
      {"/w=800/h=600", :missing_source_marker},
      {"/w=800/src", :missing_source},
      {"/src/%zz", :malformed_percent_escape},
      {"/src64/abc/def", :src64_embedded_slash},
      {"/src64/YQ==", :src64_padding},
      {"/src64/not!valid", :invalid_base64},
      {"/w=%38%30%30/src/x", :percent_in_option_segment},
      {"/w=800//h=600/src/x", :empty_segment},
      {"/./w=800/src/x", :dot_segment}
    ]

    for {path, reason} <- @path_reasons do
      test "#{reason} carries a real message (#{path})" do
        conn = conn_for(unquote(path))

        assert {:error, diagnostics} = Path.extract(conn)
        diagnostic = Enum.find(diagnostics, &(&1.reason == unquote(reason)))

        assert %Diagnostic{message: message} = diagnostic
        assert is_binary(message) and message != ""
      end
    end
  end

  describe "Path.extract/1 bound: max option segments per request (64)" do
    defp segments_path(count) do
      "/" <> Enum.map_join(1..count, "/", fn _ -> "w=1" end) <> "/src/x"
    end

    test "exactly 64 option segments succeeds" do
      conn = conn_for(segments_path(64))

      assert {:ok, %{segments: segments}} = Path.extract(conn)
      assert length(segments) == 64
    end

    test "65 option segments is a bounded :too_many_segments error, not a slow scan" do
      conn = conn_for(segments_path(65))

      assert {:error, diagnostics} = Path.extract(conn)
      assert Enum.any?(diagnostics, &(&1.reason == :too_many_segments))
    end
  end

  # -- migration: Parser.parse/2 emits %Diagnostic{} structs --------------

  describe "Parser.parse/2 emits %Diagnostic{} structs" do
    test "every error is a %Diagnostic{} with a non-empty message and a non-empty spans list" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["bogus=10", "w=notanumber"])
      assert diagnostics != []

      for diagnostic <- diagnostics do
        assert %Diagnostic{reason: reason, message: message, spans: spans} = diagnostic
        assert is_atom(reason)
        assert is_binary(message) and message != ""
        assert is_list(spans) and spans != []
      end
    end

    test "a duplicate-key diagnostic carries every participating span in one Diagnostic" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "w=900"])

      assert %Diagnostic{reason: :duplicate_option, spans: spans} =
               Enum.find(diagnostics, &(&1.reason == :duplicate_option))

      assert length(spans) == 2
    end

    # Every reason a real OptionSpec-driven value parse, or a structural
    # rule, can produce — completeness is asserted here rather than by
    # calling a private message table directly (see Test guidelines: no
    # private-implementation tests).
    @parser_reasons [
      {["bogus=10"], :unknown_option},
      {["w"], :missing_value},
      {["w=xyz"], :invalid_dimension},
      {["fit=bogus"], :invalid_fit},
      {["crop=600"], :invalid_arity},
      {["crop=abc,def"], :invalid_element},
      {["anchor=bogus"], :invalid_anchor},
      {["blur=abc"], :invalid_blur},
      {["pad=1,2,3,4,5"], :invalid_pad_shorthand},
      {["output=bogus"], :invalid_output},
      {["format=bogus"], :invalid_format},
      {["q=999"], :invalid_quality},
      {["expires=-5"], :invalid_expires},
      {["preset=bad!name"], :invalid_preset_name},
      {["w=800", "enlarge=true"], :true_spelled_bare},
      {["w=800", "enlarge=xyz"], :invalid_flag},
      {["w=800", "w=900"], :duplicate_option},
      {["then", "w=800"], :empty_pipeline_group},
      {["crop=600,400", "region=0,0,600,400"], :mutually_exclusive_options},
      {["fit=cover"], :inert_option}
    ]

    for {segments, reason} <- @parser_reasons do
      test "#{reason} carries a real message (#{inspect(segments)})" do
        assert {:error, {:invalid_request, diagnostics}} = parse(unquote(segments))
        diagnostic = Enum.find(diagnostics, &(&1.reason == unquote(reason)))

        assert %Diagnostic{message: message} = diagnostic
        assert is_binary(message) and message != ""
      end
    end
  end

  describe "parse_option_fragment/2 emits %Diagnostic{} structs" do
    @fragment_reasons [
      {"w=800/then/h=400", :then_not_allowed_in_fragment},
      {"w=800/src", :source_not_allowed_in_fragment},
      {"w=800/format=webp", :request_scoped_key_in_fragment}
    ]

    for {fragment_string, reason} <- @fragment_reasons do
      test "#{reason} carries a real message (#{fragment_string})" do
        assert {:error, diagnostics} = fragment(unquote(fragment_string))
        diagnostic = Enum.find(diagnostics, &(&1.reason == unquote(reason)))

        assert %Diagnostic{message: message} = diagnostic
        assert is_binary(message) and message != ""
      end
    end
  end

  # -- derivative suppression, at the Diagnostic/render level -------------

  describe "derivative suppression [native §Error diagnostics]" do
    test "w=invalid/enlarge reports only the invalid width, as a single %Diagnostic{}" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=invalid", "enlarge"])

      assert [%Diagnostic{reason: :invalid_dimension, message: message}] = diagnostics
      assert message != ""

      rendered =
        "/w=invalid/enlarge/src/images/cat.jpg"
        |> DiagnosticRenderer.render(diagnostics)
        |> IO.iodata_to_binary()

      assert rendered =~ message
      refute rendered =~ "requires"
    end
  end
end
