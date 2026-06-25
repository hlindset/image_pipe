defmodule ImagePipe.Transform.Detector.ImageVision.Objects do
  @moduledoc """
  `ImagePipe.Transform.Detector` for general objects, backed by the optional
  `image_vision` dependency (`Image.Detection`, RT-DETR, COCO-80). The dependency
  is not declared by ImagePipe — hosts opt in. When absent, `available?/1` is
  false and callers fall back gracefully.

  Class names use the URL-facing underscore spelling (`traffic_light`); the model
  emits spaces (`"traffic light"`), which this adapter normalizes on both sides.
  """
  @behaviour ImagePipe.Transform.Detector

  @compile {:no_warn_undefined, Image.Detection}

  @repo "onnx-community/rtdetr_r50vd"
  @filename "onnx/model.onnx"
  @min_score 0.5

  # COCO-80, underscore spelling. Hardcoded (not derived from Image.Detection)
  # so routing/availability work when the dependency is absent. A tagged drift
  # test asserts this matches the model's labels.
  @coco_classes ~w(
    person bicycle car motorcycle airplane bus train truck boat traffic_light
    fire_hydrant stop_sign parking_meter bench bird cat dog horse sheep cow
    elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee
    skis snowboard sports_ball kite baseball_bat baseball_glove skateboard
    surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl banana
    apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch
    potted_plant bed dining_table toilet tv laptop mouse remote keyboard
    cell_phone microwave oven toaster sink refrigerator book clock vase scissors
    teddy_bear hair_drier toothbrush
  )

  @impl true
  def supported_classes(_opts), do: @coco_classes

  @impl true
  def available?(_opts), do: Code.ensure_loaded?(Image.Detection)

  @impl true
  def identity(_opts) do
    if available?([]),
      do: {__MODULE__, {@repo, @filename, @min_score}},
      else: {__MODULE__, :unavailable}
  end

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, :all)

    if available?(opts),
      do: detect_objects(image, classes),
      else: {:error, {:detector, :unavailable}}
  end

  @impl true
  def warmup(opts) do
    if available?(opts) do
      {:ok, blank} = Image.new(64, 64, color: :black)
      _ = detect_objects(blank, :all)
      :ok
    else
      {:error, {:detector, :unavailable}}
    end
  end

  # Image.Detection.detect/2 lives in the optional image_vision+ortex stack
  # (the IMAGE_VISION=1 test lane); absent it, Dialyzer sees an unknown function.
  @dialyzer {:nowarn_function, detect_objects: 2}
  defp detect_objects(image, classes) do
    regions =
      image
      |> Image.Detection.detect(min_score: @min_score, repo: @repo, filename: @filename)
      |> Enum.map(fn %{label: label, score: score, box: box} ->
        %{label: String.replace(label, " ", "_"), score: score, box: box}
      end)
      |> filter_classes(classes)

    {:ok, regions}
  rescue
    error -> {:error, {:detector, error}}
  end

  defp filter_classes(regions, :all), do: regions

  defp filter_classes(regions, classes) when is_list(classes) do
    wanted = MapSet.new(classes)
    Enum.filter(regions, fn %{label: label} -> MapSet.member?(wanted, label) end)
  end
end
