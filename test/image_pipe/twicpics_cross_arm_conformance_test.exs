defmodule ImagePipe.TwicpicsCrossArmConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness}

  @arms [:framework, :dialect]
  @constellations Constellations.all()
  @constellations_by_id Map.new(@constellations, &{&1.id, &1})
  @body_sha256_categories %{
    arithmetic: ["number_fold_asymmetric"],
    focus_carry: ["crop_region_carry_far"],
    inside_transparency: ["inside_wide_lr"],
    positional_order: ["focus_carry_then_crop", "focus_carry_resize_then_crop"],
    ratio_crop: ["cover_ratio_wide"]
  }
  @body_sha256_by_id for {category, ids} <- @body_sha256_categories,
                         id <- ids,
                         into: %{},
                         do: {id, category}

  for constellation <- @constellations do
    @c constellation
    @body_category Map.get(@body_sha256_by_id, constellation.id)

    test "#{@c.id}: framework and dialect render exact local pixels" do
      {framework, dialect} = render_both(@c)

      assert framework.status == dialect.status
      assert framework.content_type == dialect.content_type
      assert PixelCompare.dims(framework.image) == PixelCompare.dims(dialect.image)
      assert Image.bands(framework.image) == Image.bands(dialect.image)
      assert PixelCompare.outliers(framework.image, dialect.image, 0) == 0

      if @body_category do
        assert sha256(framework.body) == sha256(dialect.body),
               "#{@c.id} (#{@body_category}) has exact pixels but different PNG bytes"
      end
    end
  end

  test "focus-before and focus-after resize remain order-sensitive within each arm" do
    before_resize = constellation!("focus_carry_resize_then_crop")
    after_resize = constellation!("focus_carry_then_crop")

    for arm <- @arms do
      before = render_arm(before_resize, arm)
      after_response = render_arm(after_resize, arm)

      assert PixelCompare.dims(before.image) == PixelCompare.dims(after_response.image)
      assert PixelCompare.outliers(before.image, after_response.image, 0) > 0
    end
  end

  defp render_both(constellation) do
    {
      render_arm(constellation, :framework),
      render_arm(constellation, :dialect)
    }
  end

  defp render_arm(constellation, arm) do
    path = Constellations.twicpics_path(constellation)
    {plug, plug_opts} = Harness.plug_opts(arm)
    conn = :get |> conn(path) |> plug.call(plug_opts)
    body = conn.resp_body

    %{
      status: conn.status,
      content_type: content_type(conn),
      body: body,
      image: Image.open!(body, access: :random, fail_on: :error)
    }
  end

  defp content_type(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [value | _rest] -> value |> String.split(";") |> List.first()
      [] -> nil
    end
  end

  defp constellation!(id), do: Map.fetch!(@constellations_by_id, id)

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end
end
