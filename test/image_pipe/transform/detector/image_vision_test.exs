defmodule ImagePipe.Transform.Detector.ImageVisionTest do
  use ExUnit.Case, async: true

  # The drift/smoke tests below reference the optional dependency's modules
  # (`Image.Detection`/`Image.FaceDetection`), which are absent in the default
  # lane (these tests are `@tag :image_vision` and excluded there). Silence the
  # compile-time undefined-module warning the same way the adapters do.
  @compile {:no_warn_undefined, [Image.Detection, Image.FaceDetection]}

  alias ImagePipe.Transform.Detector.ImageVision.Face
  alias ImagePipe.Transform.Detector.ImageVision.Objects

  test "identity reflects availability" do
    expected =
      if Face.available?([]),
        do: {Face, {"opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx"}},
        else: {Face, :unavailable}

    assert Face.identity([]) == expected
  end

  test "detect returns unavailable when the dependency is absent" do
    # In the default (no-dep) lane, available? is false → detect short-circuits.
    if Face.available?([]) do
      assert {:ok, _} = Face.detect(Image.new!(64, 64, color: :black), classes: ["face"])
    else
      assert {:error, {:detector, :unavailable}} =
               Face.detect(Image.new!(64, 64, color: :black), classes: ["face"])
    end
  end

  test "warmup returns unavailable when the dependencies are absent" do
    for adapter <- [Face, Objects], not adapter.available?([]) do
      assert {:error, {:detector, :unavailable}} = adapter.warmup([])
    end
  end

  @tag :image_vision
  @tag :tmp_dir
  test "warmup propagates corrupt model errors", %{tmp_dir: tmp_dir} do
    for {repo, filename} <- [
          {"opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx"},
          {"onnx-community/rtdetr_r50vd", "onnx/model.onnx"}
        ] do
      path = Path.join([tmp_dir, repo, filename])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "invalid ONNX model")
    end

    # A fresh VM avoids the dependency's in-memory model cache and isolates the
    # temporary disk cache from concurrent real-model tests.
    script = """
    Application.put_env(:image_vision, :cache_dir, hd(System.argv()))
    {:ok, _} = Application.ensure_all_started(:vix)

    for adapter <- [ImagePipe.Transform.Detector.ImageVision.Face,
                    ImagePipe.Transform.Detector.ImageVision.Objects] do
      true = adapter.available?([])
      {:error, {:detector, error}} = adapter.warmup([])
      true = is_exception(error)
    end
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script, tmp_dir],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "Face.detect with :all short-circuits to unavailable when the dep is absent" do
    # Only meaningful in the no-dependency lane: when available? is false the
    # detect short-circuits before touching the (junk) :image input. With the dep
    # present it would run real inference, so guard to that lane.
    unless Face.available?([]) do
      assert {:error, {:detector, :unavailable}} = Face.detect(:image, classes: :all)
      assert {:error, {:detector, :unavailable}} = Face.detect(:image, classes: ["car"])
    end
  end

  @tag :image_vision
  test "detect returns face regions when the dependency is present" do
    unless Face.available?([]) do
      flunk("""
      The :image_vision lane needs the real face detector, but Image.FaceDetection \
      is not loaded (available?([]) == false). image_vision compiles that module \
      only when its ONNX backend is configured (`if ImageVision.ortex_configured?()`), \
      so the lane requires BOTH `:image_vision` and `:ortex` (a Rust/ONNX runtime). \
      Both are in the IMAGE_VISION-gated deps in mix.exs — run \
      `IMAGE_VISION=1 mix deps.get` (needs a Rust toolchain); the YuNet model \
      (~340 KB) downloads from HuggingFace on the first detect call.\
      """)
    end

    image = Image.open!("priv/static/images/woman.jpg")
    assert :ok = Face.warmup([])
    assert {:ok, regions} = Face.detect(image, classes: ["face"])
    assert Enum.all?(regions, &match?(%{label: "face", box: {_, _, _, _}}, &1))
  end

  describe "Face.detect routing (real model)" do
    @describetag :image_vision

    test "classes: :all returns faces; a non-face routed class returns no regions" do
      {:ok, image} = Image.new(64, 64, color: :black)
      assert {:ok, regions} = Face.detect(image, classes: :all)
      assert is_list(regions)
      assert {:ok, []} = Face.detect(image, classes: ["car"])
    end
  end

  # supported_classes is a hardcoded static list (dep-independent), so this runs
  # in the DEFAULT lane — it is the deterministic coverage for the underscore
  # spelling that the normalization depends on.
  describe "Objects vocabulary (no dependency required)" do
    test "supported_classes is the static COCO-80 vocabulary in underscore spelling" do
      classes = Objects.supported_classes([])
      assert "person" in classes
      assert "traffic_light" in classes
      refute "traffic light" in classes
      assert length(classes) == 80
    end
  end

  describe "Objects adapter (real model)" do
    @describetag :image_vision

    test "supported_classes matches the model's labels (drift guard)" do
      model_labels =
        Image.Detection.classes()
        |> Enum.map(&String.replace(&1, " ", "_"))
        |> Enum.sort()

      assert Enum.sort(Objects.supported_classes([])) == model_labels
    end

    test "detect returns product-neutral regions on a synthetic image" do
      assert :ok = Objects.warmup([])
      {:ok, image} = Image.new(320, 240, color: :black)
      assert {:ok, regions} = Objects.detect(image, classes: :all)
      assert is_list(regions)

      assert Enum.all?(
               regions,
               &match?(%{label: l, score: _, box: {_, _, _, _}} when is_binary(l), &1)
             )
    end
  end
end
