defmodule ImagePipe.Dialect.IIIF.ParseTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Dialect.IIIF.Config
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @opts [
    resolver:
      {ImagePipe.Dialect.IIIF.Resolver.Static,
       map: %{"abc" => %SourcePath{segments: ["beach.jpg"]}}}
  ]

  defp validated(opts \\ @opts), do: Config.validate!(opts)

  defp opts_with(extra), do: Keyword.merge(@opts, extra)

  describe "parse_plan/2 (the declarative host callback)" do
    test "image request -> {:ok, %Plan{}} with explicit jpeg output" do
      assert {:ok, %Plan{render: :image, output: %{mode: {:explicit, :jpeg}}}} =
               IIIF.parse_plan(conn(:get, "/abc/full/max/0/default.jpg"), validated())
    end

    test "bare identifier -> {:redirect, 303, absolute info.json}" do
      conn = %{conn(:get, "/abc") | script_name: ["iiif"]}
      assert {:redirect, 303, location} = IIIF.parse_plan(conn, validated())
      assert String.ends_with?(location, "/iiif/abc/info.json")
    end

    test "unknown identifier -> {:error, :not_found}" do
      assert {:error, :not_found} =
               IIIF.parse_plan(conn(:get, "/nope/full/max/0/default.jpg"), validated())
    end

    test "bad rotation token -> {:error, {:invalid_rotation, _}}" do
      assert {:error, {:invalid_rotation, "370"}} =
               IIIF.parse_plan(conn(:get, "/abc/full/max/370/default.jpg"), validated())
    end

    test "info request -> render plan with InfoRenderer + id param" do
      {:ok,
       %Plan{
         render: {:custom, ImagePipe.Dialect.IIIF.InfoRenderer, params},
         output: nil,
         pipelines: []
       }} =
        IIIF.parse_plan(conn(:get, "/abc/info.json"), validated())

      assert params.id =~ "/abc"
      assert params.offers != []
    end
  end

  # The base wraps `parse_plan/2` in the behaviour's `parse/2`: a `{result,
  # span_metadata}` pair whose failures ride a `%Failure{phase: :parse}`
  # envelope. Both halves are what the runner and the dialect's own
  # `render_error/3` consume, so they are asserted directly.
  describe "parse/2 (the behaviour surface)" do
    test "an image request carries :ok span metadata" do
      assert {{:ok, %Plan{}}, %{result: :ok}} =
               IIIF.parse(conn(:get, "/abc/full/max/0/default.jpg"), validated())
    end

    test "a rejection is wrapped in %Failure{phase: :parse} and tagged in span metadata" do
      assert {{:error, %Failure{phase: :parse, reason: :not_found}},
              %{result: :error, error: :not_found}} =
               IIIF.parse(conn(:get, "/nope/full/max/0/default.jpg"), validated())
    end

    test "a base-URI redirect carries its status in span metadata" do
      assert {{:redirect, 303, _location}, %{result: :redirect, status: 303}} =
               IIIF.parse(conn(:get, "/abc"), validated())
    end
  end

  describe "max bounds option validation" do
    test "accepts max_width alone (does not raise)" do
      assert Keyword.fetch!(validated(opts_with(max_width: 2000)), :max_width) == 2000
    end

    test "accepts max_width + max_height" do
      config = validated(opts_with(max_width: 2000, max_height: 1500))
      assert Keyword.fetch!(config, :max_width) == 2000
      assert Keyword.fetch!(config, :max_height) == 1500
    end

    test "accepts max_area alone" do
      assert Keyword.fetch!(validated(opts_with(max_area: 3_000_000)), :max_area) == 3_000_000
    end

    test "rejects max_height without max_width" do
      assert_raise ArgumentError, ~r/max_height requires max_width/, fn ->
        validated(opts_with(max_height: 1500))
      end
    end

    test "rejects a non-positive bound" do
      assert_raise ArgumentError, ~r/max_width/, fn ->
        validated(opts_with(max_width: 0))
      end
    end
  end

  describe "neutral config" do
    test "accepts and resolves a neutral quality key" do
      config = validated(opts_with(quality: 90))
      assert Keyword.fetch!(config, :quality) == 90
      assert Keyword.fetch!(config, :tile_size) == 512
    end

    test "auto_rotate is a neutral key (honored, default true)" do
      assert Keyword.fetch!(validated(), :auto_rotate) == true
      assert Keyword.fetch!(validated(opts_with(auto_rotate: false)), :auto_rotate) == false
    end

    test "rejects an unknown dialect key" do
      assert_raise ArgumentError, ~r/unknown ImagePipe\.Dialect\.IIIF option/, fn ->
        validated(opts_with(bogus: 1))
      end
    end

    test "raises at init for autoquality :size with no target" do
      assert_raise ArgumentError, ~r/autoquality/, fn ->
        validated(opts_with(autoquality_method: :size))
      end
    end
  end
end
