defmodule ImagePipe.Decode.Streaming do
  @moduledoc false
  alias Image.Options.Open
  alias ImagePipe.Decode.SourceFormat
  alias ImagePipe.Format.Detector
  alias ImagePipe.Source.Download
  alias Vix.Vips.Image, as: VipsImage

  def eligible?(prefix) do
    with format when format in [:jpeg, :png] <- Detector.detect(prefix),
         {:ok, image} <- Image.from_binary(prefix, access: :random, fail_on: :error),
         {:ok, ^format} <- SourceFormat.from_image(image) do
      true
    else
      _ -> false
    end
  end

  def open(download, options) do
    owner = self()

    # Download owns and monitors the Vix feeder independently of the decoder.
    # A failed/closed native pipe must not take the processing worker down.
    stream =
      Stream.transform(
        Download.stream(download),
        fn -> Process.unlink(owner) end,
        fn bytes, state -> {[bytes], state} end,
        fn _state -> :ok end
      )

    with {:ok, options} <- Open.validate_options(options) do
      VipsImage.new_from_enum(stream, options)
    end
  end
end
