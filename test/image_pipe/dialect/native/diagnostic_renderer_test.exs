defmodule ImagePipe.Dialect.Native.DiagnosticRendererTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Native.Diagnostic
  alias ImagePipe.Dialect.Native.DiagnosticRenderer

  defp diag(reason, message, spans) do
    %Diagnostic{reason: reason, message: message, spans: spans}
  end

  defp render(path, diagnostics) do
    path
    |> DiagnosticRenderer.render(diagnostics)
    |> IO.iodata_to_binary()
  end

  describe "the spec's worked example [native §Error diagnostics]" do
    test "reproduces the caret display byte-exact" do
      path = "/crop=1000,1000/w=500/bogus=10/h=invalid/src/images/cat.jpg"

      diagnostics = [
        diag(:unknown_option, "unknown option", [{22, 8}]),
        diag(:invalid_dimension, "invalid value: expected px or `auto`", [{33, 7}])
      ]

      expected =
        "invalid transformation options\n" <>
          "\n" <>
          "/crop=1000,1000/w=500/bogus=10/h=invalid/src/images/cat.jpg\n" <>
          "                      ^^^^^^^^   ^^^^^^^\n" <>
          "                      |          |\n" <>
          "                      |          invalid value: expected px or `auto`\n" <>
          "                      unknown option\n"

      assert render(path, diagnostics) == expected
    end
  end

  describe "accumulation" do
    test "two independent errors both render, each with its own caret and label" do
      path = "/w=800/bogus=10/src/x"

      diagnostics = [
        diag(:invalid_dimension, "invalid width", [{1, 5}]),
        diag(:unknown_option, "unknown option", [{7, 8}])
      ]

      rendered = render(path, diagnostics)

      assert rendered =~ "invalid width"
      assert rendered =~ "unknown option"
      assert rendered =~ path
    end

    test "three independent single-span diagnostics cascade in general (not just N=2)" do
      path = "0123456789ABCDEFGHIJ"

      diagnostics = [
        diag(:r1, "first", [{0, 2}]),
        diag(:r2, "second", [{8, 2}]),
        diag(:r3, "third", [{16, 2}])
      ]

      expected =
        "invalid transformation options\n" <>
          "\n" <>
          "0123456789ABCDEFGHIJ\n" <>
          "^^      ^^      ^^\n" <>
          "|       |       |\n" <>
          "|       |       third\n" <>
          "|       second\n" <>
          "first\n"

      assert render(path, diagnostics) == expected
    end
  end

  describe "multi-span underline" do
    test "a diagnostic with two spans (e.g. a duplicate key) underlines both, with one label" do
      path = "AAAAA12345BBBBB"

      diagnostics = [
        diag(:duplicate_option, "duplicate option", [{0, 5}, {10, 5}])
      ]

      expected =
        "invalid transformation options\n" <>
          "\n" <>
          "AAAAA12345BBBBB\n" <>
          "^^^^^     ^^^^^\n" <>
          "|\n" <>
          "duplicate option\n"

      assert render(path, diagnostics) == expected
    end
  end

  describe "bound: max collected diagnostics rendered (16)" do
    test "renders at most 16 diagnostics and summarizes the rest in an omitted-count line" do
      path = String.duplicate("x", 200)

      diagnostics =
        for i <- 0..19 do
          diag(:"r#{i}", "e#{i}", [{i * 5, 1}])
        end

      rendered = render(path, diagnostics)

      for i <- 0..15 do
        assert rendered =~ "e#{i}"
      end

      for i <- 16..19 do
        refute rendered =~ "e#{i}"
      end

      assert rendered =~ "4 further errors omitted"
    end

    test "does not add an omitted-count line when at or under the cap" do
      path = String.duplicate("x", 100)
      diagnostics = for i <- 0..15, do: diag(:"r#{i}", "e#{i}", [{i * 5, 1}])

      refute render(path, diagnostics) =~ "omitted"
    end
  end

  describe "bound: max echoed path bytes (2048)" do
    test "truncates a longer path with a marker, and does not grow carets into it" do
      path = String.duplicate("a", 2050)

      rendered = render(path, [])

      assert rendered =~ String.duplicate("a", 2048) <> "...[truncated]"
      refute rendered =~ String.duplicate("a", 2049)
    end

    test "does not truncate a path at or under the cap" do
      path = String.duplicate("a", 2048)

      rendered = render(path, [])

      assert rendered =~ path
      refute rendered =~ "truncated"
    end
  end

  describe "bound: max rendered body bytes (8192)" do
    test "truncates the whole rendered body with a marker" do
      path = String.duplicate("p", 6000)

      diagnostics =
        for i <- 0..15 do
          diag(:"r#{i}", String.duplicate("m", 300), [{i * 300, 5}])
        end

      rendered = render(path, diagnostics)

      assert byte_size(rendered) <= 8192
      assert rendered =~ "...[truncated]"
    end

    test "does not truncate a small rendered body" do
      rendered = render("/w=800/src/x", [diag(:unknown_option, "unknown option", [{1, 5}])])

      refute rendered =~ "...[truncated]"
    end
  end
end
