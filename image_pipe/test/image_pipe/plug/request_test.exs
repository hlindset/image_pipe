defmodule ImagePipe.Plug.RequestTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Plug.Request

  setup do
    %{config: ImagePipe.Plug.init([])}
  end

  defp mounted(path, script_name), do: %{conn(:get, path) | script_name: script_name}

  describe "parse/2 mount prefix" do
    test "strips a multi-segment mount prefix as a raw string prefix", %{config: config} do
      conn = mounted("/api/v2/w=800/src/x", ["api", "v2"])

      assert {{:ok, _request, "x"}, %{result: :ok}} = Request.parse(conn, config)
    end

    test "treats a request for the mount itself as an empty path", %{config: config} do
      conn = mounted("/mount", ["mount"])

      assert {{:error, {:invalid_request, [%{reason: :missing_source_marker}]}}, _metadata} =
               Request.parse(conn, config)
    end

    test "strips percent-encoded mount segments as Plug.forward leaves them", %{config: config} do
      conn = mounted("/a%20b/50%25/w=800/src/x", ["a%20b", "50%25"])

      assert {{:ok, _request, "x"}, %{result: :ok}} = Request.parse(conn, config)
    end

    test "strips mount segments by count across repeated slashes", %{config: config} do
      conn = mounted("//api//v2/w=800/src/x", ["api", "v2"])

      assert {{:ok, _request, "x"}, %{result: :ok}} = Request.parse(conn, config)
    end
  end
end
