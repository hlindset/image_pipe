defmodule ImagePipe.Transform.InputColorManagementSequentialTest do
  @moduledoc """
  Sequential-safety gate for the input-color-management preamble.

  Per the project's sequential-safety rule, before treating `condition/2` as
  streamable we must prove its pixels match between a genuinely streamed open
  (`access: :sequential, fail_on: :error`) and a random-access open of the same
  source — including the 16-bit-alpha band split/rejoin path, which reorders
  bands. The harness includes the required known-random self-check (a raw
  90-degree rotate built on the streamed open must error when its pixels are
  pulled) so the equivalence assertions cannot pass tautologically.

  This proves correctness, not the memory win (the silent-buffering failure mode
  is a separate, deferred high-water-mark benchmark).
  """
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.InputColorManagement, as: ICM
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage

  @sources "test/support/image_pipe/test/sources"
  @p3_fixture "#{@sources}/icc_p3.png"
  @cmyk_fixture "#{@sources}/cmyk.jpg"
  @rgb16_fixture "#{@sources}/rgb16.png"
  @rgba16_fixture "#{@sources}/rgba16.png"

  # A large source so the streamed open genuinely cannot buffer; used only for
  # the self-check below.
  @large_source "priv/static/images/beach.jpg"

  describe "harness self-check" do
    test "sequential open genuinely streams (a raw 90-degree rotate errors at evaluation)" do
      body = File.read!(@large_source)
      {:ok, image} = Image.open([body], access: :sequential, fail_on: :error)
      {:ok, rotated} = Image.rotate(image, 90)

      assert {:error, _reason} = VixImage.copy_memory(rotated)
    end
  end

  describe "condition/2 sequential-vs-random pixel equivalence" do
    test "wide-gamut (Display-P3) import streams" do
      assert_condition_sequential_matches_random(@p3_fixture)
    end

    test "CMYK import streams" do
      assert_condition_sequential_matches_random(@cmyk_fixture)
    end

    test "16-bit RGB import streams" do
      assert_condition_sequential_matches_random(@rgb16_fixture)
    end

    test "16-bit RGB with alpha (band split/rejoin) streams" do
      assert_condition_sequential_matches_random(@rgba16_fixture)
    end
  end

  describe "condition/2 followed by a quarter-turn rotate" do
    test "wide-gamut import then rotate stays pixel-equivalent" do
      assert_condition_then_rotate_matches_random(@p3_fixture)
    end

    test "16-bit RGB with alpha import then rotate stays pixel-equivalent" do
      assert_condition_then_rotate_matches_random(@rgba16_fixture)
    end
  end

  defp assert_condition_sequential_matches_random(path) do
    {:ok, random_image} = run_condition(path, :random)
    {:ok, sequential_image} = run_condition(path, :sequential)

    assert_images_match(sequential_image, random_image)
  end

  defp assert_condition_then_rotate_matches_random(path) do
    {:ok, random_image} = run_condition_then_rotate(path, :random)
    {:ok, sequential_image} = run_condition_then_rotate(path, :sequential)

    assert_images_match(sequential_image, random_image)
  end

  defp run_condition(path, access) when access in [:random, :sequential] do
    body = File.read!(path)

    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         {:ok, %State{} = state} <- ICM.condition(%State{image: image}, supports_hdr?: false) do
      VixImage.copy_memory(state.image)
    end
  end

  defp run_condition_then_rotate(path, access) when access in [:random, :sequential] do
    body = File.read!(path)

    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         {:ok, %State{} = state} <- ICM.condition(%State{image: image}, supports_hdr?: false),
         {:ok, rotated} <- Image.rotate(state.image, 90) do
      VixImage.copy_memory(rotated)
    end
  end

  defp assert_images_match(left, right) do
    assert Image.width(left) == Image.width(right)
    assert Image.height(left) == Image.height(right)
    assert VixImage.bands(left) == VixImage.bands(right)
    assert VixImage.interpretation(left) == VixImage.interpretation(right)
    assert_sampled_pixels_match(left, right)
  end

  defp assert_sampled_pixels_match(left, right) do
    for x <- sample_positions(Image.width(left)),
        y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y)
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end
end
