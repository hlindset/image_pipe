defmodule ImagePipe.Transform.Detector.ImageVision.Face do
  @moduledoc """
  `ImagePipe.Transform.Detector` for faces, backed by the optional `image_vision`
  dependency (`Image.FaceDetection`, YuNet). The dependency is not declared by
  ImagePipe — hosts opt in. When absent, `available?/1` is false and callers fall
  back gracefully.

  Faces with a confidence score below 0.6 are dropped before ImagePipe sees
  them.
  """
  @behaviour ImagePipe.Transform.Detector

  alias ImagePipe.Transform.Detector.ImageVision.Model

  @compile {:no_warn_undefined, [Image.FaceDetection, ImageVision.ModelCache]}

  @repo "opencv/face_detection_yunet"
  @model_file "face_detection_yunet_2023mar.onnx"
  @min_score 0.6

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def available?(_opts), do: Code.ensure_loaded?(Image.FaceDetection)

  # Model files live in image_vision's on-disk cache; a miss would download.
  @impl true
  @dialyzer {:nowarn_function, ready?: 1}
  def ready?(opts), do: available?(opts) and ImageVision.ModelCache.cached?(@repo, @model_file)

  @impl true
  def identity(_opts),
    do: Model.identity(__MODULE__, available?([]), {@repo, @model_file, @min_score})

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
      |> Image.FaceDetection.detect(min_score: @min_score)
      |> Enum.map(fn %{box: box, score: score} -> %{label: "face", score: score, box: box} end)

    {:ok, regions}
  rescue
    error -> {:error, {:detector, error}}
  end
end
