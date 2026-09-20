defmodule ImagePipe.RunTest do
  use ExUnit.Case, async: true

  alias ImagePipe, as: IP
  alias ImagePipe.Plan
  alias ImagePipe.Processing
  alias ImagePipe.Processing.Config
  alias ImagePipe.RunTest.LateFailureEncoder
  alias ImagePipe.RunTest.OwnedSource
  alias ImagePipe.Source

  setup do
    image = Image.new!(60, 40, color: [80, 120, 160])
    %{bytes: Image.write!(image, :memory, suffix: ".png")}
  end

  test "runs a plan against bytes without a connection or URL", %{bytes: bytes} do
    plan = IP.new() |> IP.group(resize: [width: 30]) |> IP.output(format: :png)
    assert {:ok, result} = IP.run(plan, {:binary, bytes})
    assert result.terminal == :image
    assert result.format == :png
    assert result.content_type == "image/png"
    assert {result.width, result.height} == {30, 20}
    assert Image.shape(Image.from_binary!(result.data)) == {30, 20, 3}
  end

  test "runs files and writes fully consumed output", %{bytes: bytes} do
    dir = Path.join(System.tmp_dir!(), "image-pipe-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    input = Path.join(dir, "input.png")
    output = Path.join(dir, "output.webp")
    File.write!(input, bytes)
    plan = IP.new() |> IP.output(format: :webp)
    assert {:ok, result} = IP.write(plan, {:file, input}, output)
    assert File.read!(output) == result.data
    assert result.format == :webp
  end

  test "returns structured info and direct placeholder values", %{bytes: bytes} do
    assert {:ok, info} = IP.run(IP.output(IP.new(), terminal: :info), {:binary, bytes})
    assert info.data["width"] == 60
    assert info.data["height"] == 40
    assert info.data["size"] == byte_size(bytes)

    for terminal <- [:blurhash, :lqip_css] do
      assert {:ok, result} = IP.run(IP.output(IP.new(), terminal: terminal), {:binary, bytes})
      assert result.terminal == terminal
      assert is_binary(result.data)
      assert byte_size(result.data) > 0
    end
  end

  test "rejects invalid plans before reading a file" do
    plan = IP.new() |> IP.group(extend: true)
    assert {:error, {:invalid_request, [_issue]}} = IP.run(plan, {:file, "/missing/photo.png"})
  end

  test "validates configuration separately from runtime failures", %{bytes: bytes} do
    assert_raise ArgumentError, fn -> IP.run(IP.new(), {:binary, bytes}, unknown: true) end
    assert_raise ArgumentError, fn -> IP.run(IP.new(), {:binary, bytes}, cache: nil) end

    assert {:error, {:source, :body_too_large}} =
             IP.run(IP.new(), {:binary, bytes}, max_body_bytes: 10)

    assert {:error, {:input_limit, _reason}} =
             IP.run(IP.new(), {:binary, bytes}, max_input_pixels: 10)

    assert {:error, {:decode, _reason}} = IP.run(IP.new(), {:binary, "not an image"})
  end

  test "configured adapters close resources on success, decode, transform, and destination errors",
       %{bytes: bytes} do
    options = owned_source(bytes)
    input = {:source, "private/photo.png"}
    assert {:ok, _result} = IP.run(IP.new(), input, options)
    assert_closed()

    assert {:error, {:decode, _reason}} = IP.run(IP.new(), input, owned_source("corrupt"))
    assert_closed()

    invalid_region = IP.new() |> IP.group(region: {1000, 1000, 10, 10})
    assert {:error, {:transform, _reason}} = IP.run(invalid_region, input, options)
    assert_closed()

    destination =
      Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}/out.png")

    assert {:error, {:destination, :enoent}} = IP.write(IP.new(), input, destination, options)
    assert_closed()
  end

  test "shared buffered generation consumes late encoder failures before closing the source", %{
    bytes: bytes
  } do
    config =
      bytes
      |> owned_source()
      |> Config.validate!()
      |> Keyword.put(:image_module, LateFailureEncoder)

    assert {:ok, request} = Plan.to_request(IP.output(IP.new(), format: :jpeg), "")
    assert {:ok, policy} = Processing.prepare(request, config, "")
    assert {:ok, source, config} = Source.from_input({:source, "photo.png"}, config)

    assert {:error, {:encode, %RuntimeError{}, _stack}} =
             Processing.buffer(request, source, policy, config)

    assert_received :encoder_closed
    refute_received :encoder_closed
    assert_closed()
  end

  test "preflight rejects semantic, output, expiry and capability failures before resolving a source",
       %{bytes: bytes} do
    input = {:source, "photo.png"}
    options = owned_source(bytes)

    assert {:error, {:invalid_request, _}} =
             IP.run(IP.group(IP.new(), extend: true), input, options)

    invalid_output = IP.new() |> IP.output(hdr: :preserve, color_profile: {:convert, :srgb})
    assert {:error, {:invalid_output, _}} = IP.run(invalid_output, input, options)

    assert {:error, :expired} =
             IP.run(IP.new(expires: 999), input, Keyword.put(options, :clock, fn -> 1000 end))

    assert {:error, {:unsupported_output_format, :webp}} =
             IP.run(
               IP.output(IP.new(), format: :webp),
               input,
               Keyword.put(options, :output_capabilities, %{webp: false})
             )

    refute_received :source_resolved
    refute_received :source_fetched
    refute_received :source_closed
  end

  test "expiry is valid at the exact timestamp", %{bytes: bytes} do
    assert {:ok, _result} = IP.run(IP.new(expires: 1000), {:binary, bytes}, clock: fn -> 1000 end)
  end

  test "file and input boundaries reject malformed or oversized sources", %{bytes: bytes} do
    assert {:error, {:invalid_source, :invalid_input}} = IP.run(IP.new(), bytes)
    assert {:error, {:invalid_source, :invalid_encoding}} = IP.run(IP.new(), {:source, <<255>>})
    assert {:error, {:source, :enoent}} = IP.run(IP.new(), {:file, "/missing/image.png"})
    assert {:error, {:source, :not_regular_file}} = IP.run(IP.new(), {:file, System.tmp_dir!()})
    path = "test/support/image_pipe/test/sources/small.png"

    assert {:error, {:source, :body_too_large}} =
             IP.run(IP.new(), {:file, path}, max_body_bytes: 1)
  end

  test "request and stage telemetry include outcomes without source contents", %{bytes: bytes} do
    prefix = [__MODULE__, :local]
    pid = self()
    id = make_ref()
    stages = [[:request], [:source, :fetch_decode], [:transform, :execute], [:encode]]
    events = for stage <- stages, do: prefix ++ stage ++ [:stop]

    :telemetry.attach_many(
      id,
      events,
      fn event, _measurements, metadata, _config ->
        send(pid, {:stage, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:ok, _result} = IP.run(IP.new(), {:binary, bytes}, telemetry_prefix: prefix)

    for event <- events do
      assert_receive {:stage, ^event, %{result: :ok} = metadata}
      refute Map.has_key?(metadata, :source)
    end
  end

  defp owned_source(bytes), do: [sources: [path: {OwnedSource, pid: self(), bytes: bytes}]]

  defp assert_closed do
    assert_received :source_resolved
    assert_received :source_fetched
    assert_received :stream_closed
    assert_received :source_closed
    refute_received :source_closed
  end
end
