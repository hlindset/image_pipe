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
      with {:ok, _regions} <- detect_faces(blank), do: :ok
    else
      {:error, {:detector, :unavailable}}
    end
  end

  # FaceDetection returns a bare list and raises on failure; rescue at this
  # dependency boundary. Boxes use absolute {x, y, width, height}; drop landmarks.
  # Dialyzer cannot resolve the function without the optional image_vision stack.
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
