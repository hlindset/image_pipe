defmodule ImagePipe.Transform.Detector.ImageVision.Face do
  @moduledoc """
  `ImagePipe.Transform.Detector` for faces, backed by the optional `image_vision`
  dependency (`Image.FaceDetection`, YuNet). The dependency is not declared by
  ImagePipe — hosts opt in. When absent, `available?/1` is false and callers fall
  back gracefully.
  """
  @behaviour ImagePipe.Transform.Detector

  @compile {:no_warn_undefined, Image.FaceDetection}

  @repo "opencv/face_detection_yunet"
  @model_file "face_detection_yunet_2023mar.onnx"

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def available?(_opts), do: Code.ensure_loaded?(Image.FaceDetection)

  @impl true
  def identity(_opts) do
    if available?([]),
      do: {__MODULE__, {@repo, @model_file}},
      else: {__MODULE__, :unavailable}
  end

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, [])

    cond do
      not available?(opts) -> {:error, {:detector, :unavailable}}
      classes == :all or (is_list(classes) and "face" in classes) -> detect_faces(image)
      true -> {:ok, []}
    end
  end

  @impl true
  def warmup(opts) do
    if available?(opts) do
      {:ok, blank} = Image.new(64, 64, color: :black)
      _ = detect_faces(blank)
      :ok
    else
      {:error, {:detector, :unavailable}}
    end
  end

  # Image.FaceDetection.detect/1 returns a BARE list of
  # %{box: {x,y,w,h}, score, landmarks} and RAISES on failure — wrap in a narrow
  # boundary rescue (sanctioned host/optional-dep runtime boundary). Boxes are
  # {x, y, width, height} absolute top-left pixels; landmarks are dropped.
  # Image.FaceDetection.detect/1 lives in the optional image_vision+ortex stack
  # (the IMAGE_VISION=1 test lane); absent it, Dialyzer sees an unknown function.
  @dialyzer {:nowarn_function, detect_faces: 1}
  defp detect_faces(image) do
    regions =
      image
      |> Image.FaceDetection.detect()
      |> Enum.map(fn %{box: box, score: score} -> %{label: "face", score: score, box: box} end)

    {:ok, regions}
  rescue
    error -> {:error, {:detector, error}}
  end
end
