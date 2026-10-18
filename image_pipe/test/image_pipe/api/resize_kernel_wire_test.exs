defmodule ImagePipe.API.ResizeKernelWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @jpeg File.read!("test/support/image_pipe/test/sources/high_freq.jpg")

  test "nearest and linear downscales differ from the default kernel" do
    default = request("w=300", @jpeg, "image/jpeg") |> decode()

    for kernel <- ["nearest", "linear"] do
      output = request("w=300/kernel=#{kernel}", @jpeg, "image/jpeg") |> decode()
      assert {Image.width(output), Image.height(output)} == {300, 225}
      assert mean_difference(output, default) > 2, kernel
    end
  end

  test "a nearest downscale of a JPEG samples the full-size decode" do
    output = request("w=300/kernel=nearest", @jpeg, "image/jpeg") |> decode()

    # The request decodes sequentially, which changes where libvips' nearest
    # resize samples, so the reference does too.
    expected = nearest_reference(access: :VIPS_ACCESS_SEQUENTIAL)
    shrunk = nearest_reference(access: :VIPS_ACCESS_SEQUENTIAL, shrink: 4)

    assert max_difference(output, expected) == 0
    assert mean_difference(output, shrunk) > 10
  end

  defp nearest_reference(load_options) do
    {:ok, source} = VipsImage.new_from_buffer(@jpeg, load_options)
    scale = 300 / Image.width(source)
    {:ok, resized} = Operation.resize(source, scale, kernel: :VIPS_KERNEL_NEAREST)
    {:ok, resized} = VipsImage.copy_memory(resized)
    resized
  end

  test "a nearest upscale of a checkerboard keeps hard edges" do
    {:ok, checkerboard} =
      VipsImage.new_from_binary(<<0, 255, 255, 0>>, 2, 2, 1, :VIPS_FORMAT_UCHAR)

    png = Image.write!(checkerboard, :memory, suffix: ".png")

    nearest = request("w=8/enlarge/kernel=nearest", png, "image/png") |> decode()
    assert {Image.width(nearest), Image.height(nearest)} == {8, 8}
    assert Image.get_pixel!(nearest, 3, 3) == [0]
    assert Image.get_pixel!(nearest, 4, 3) == [255]
    assert Image.get_pixel!(nearest, 3, 4) == [255]
    assert Image.get_pixel!(nearest, 4, 4) == [0]
    assert distinct_values(nearest) == [0, 255]

    default = request("w=8/enlarge", png, "image/png") |> decode()
    assert length(distinct_values(default)) > 2
  end

  test "the kernel is part of the response identity, and lanczos3 is the default" do
    etag = fn options -> request(options, @jpeg, "image/jpeg") |> get_resp_header("etag") end

    assert [_etag] = etag.("w=300")
    assert etag.("w=300/kernel=lanczos3") == etag.("w=300")
    assert etag.("w=300/kernel=nearest") != etag.("w=300")
    assert etag.("w=300/kernel=nearest") != etag.("w=300/kernel=linear")
  end

  test "a kernel without a resize is ignored" do
    plain = request("blur=1", @jpeg, "image/jpeg")
    with_kernel = request("blur=1/kernel=nearest", @jpeg, "image/jpeg")

    assert with_kernel.status == 200
    assert with_kernel.resp_body == plain.resp_body
  end

  test "an unknown kernel fails before source access" do
    origin = fn _conn -> flunk("invalid request fetched its source") end

    response =
      conn(:get, "/w=300/kernel=bilinear/src/image.jpg") |> ImagePipe.Plug.call(config(origin))

    assert response.status == 400
  end

  defp distinct_values(image) do
    {:ok, binary} = VipsImage.write_to_binary(image)
    binary |> :binary.bin_to_list() |> Enum.uniq() |> Enum.sort()
  end

  defp mean_difference(left, right) do
    {:ok, difference} = Operation.subtract(left, right)
    {:ok, magnitude} = Operation.abs(difference)
    {:ok, mean} = Operation.avg(magnitude)
    mean
  end

  defp max_difference(left, right) do
    {:ok, difference} = Operation.subtract(left, right)
    {:ok, magnitude} = Operation.abs(difference)
    {:ok, {max, _position}} = Operation.max(magnitude)
    max
  end

  defp request(options, body, content_type) do
    origin = fn conn -> conn |> put_resp_content_type(content_type) |> send_resp(200, body) end
    conn(:get, "/#{options}/format=png/src/image") |> ImagePipe.Plug.call(config(origin))
  end

  defp config(origin) do
    ImagePipe.Plug.init(
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            byte_identity: :strong,
            req_options: [plug: origin]
          ]
        ]
      ],
      http_cache: :auto
    )
  end

  defp decode(response) do
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end
end
