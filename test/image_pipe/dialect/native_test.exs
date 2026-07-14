defmodule ImagePipe.Dialect.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Native

  describe "init/1" do
    test "returns validated config for an empty option list" do
      opts = Native.init([])

      assert Keyword.fetch!(opts, :keys) == []
      assert Keyword.fetch!(opts, :presets) == %{}
      assert Keyword.fetch!(opts, :on_inert_option) == :reject
      assert Keyword.fetch!(opts, :storage_inputs) == []
      assert Keyword.fetch!(opts, :max_body_bytes) == 10_000_000
      assert Keyword.fetch!(opts, :max_input_pixels) == 40_000_000
    end

    test "raises on an unknown option" do
      assert_raise ArgumentError, fn ->
        Native.init(bogus_option: true)
      end
    end

    test "raises on a non-hex key" do
      assert_raise ArgumentError, fn ->
        Native.init(keys: ["not-hex"])
      end
    end

    test "accepts valid hex keys" do
      opts = Native.init(keys: ["deadbeef"])

      assert Keyword.fetch!(opts, :keys) == ["deadbeef"]
    end

    test "raises on on_inert_option: :ignore (not yet implemented)" do
      assert_raise ArgumentError, ~r/not yet implemented/, fn ->
        Native.init(on_inert_option: :ignore)
      end
    end

    test "raises on an invalid on_inert_option value" do
      assert_raise ArgumentError, fn ->
        Native.init(on_inert_option: :bogus)
      end
    end
  end

  describe "call/2" do
    test "returns 501 for a GET request on any path" do
      opts = Native.init([])
      conn = conn(:get, "/anything/at/all") |> Native.call(opts)

      assert conn.status == 501
    end

    test "returns 501 regardless of method or path" do
      opts = Native.init([])
      conn = conn(:post, "/") |> Native.call(opts)

      assert conn.status == 501
    end
  end
end
