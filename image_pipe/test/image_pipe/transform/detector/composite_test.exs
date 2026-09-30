defmodule ImagePipe.Transform.Detector.CompositeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Detector.Composite

  # Fake children: each owns a vocabulary and returns one canned region per
  # routed class (label = class). Real @behaviour producers, so this is not an
  # impossible-internal-misuse test.
  defmodule FaceChild do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["face"]
    @impl true
    def available?(opts), do: Keyword.get(opts, :face_available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :face_v1}
    @impl true
    def detect(_image, opts), do: {:ok, regions_for(opts)}

    defp regions_for(opts) do
      requested(opts, ["face"])
      |> Enum.map(&%{label: &1, score: 0.9, box: {0, 0, 10, 10}})
    end

    defp requested(opts, owned) do
      case Keyword.get(opts, :classes, :all) do
        :all -> owned
        list -> Enum.filter(list, &(&1 in owned))
      end
    end
  end

  defmodule ObjectChild do
    @behaviour ImagePipe.Transform.Detector
    @owned ["car", "dog"]
    @impl true
    def supported_classes(_), do: @owned
    @impl true
    def available?(opts), do: Keyword.get(opts, :object_available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :obj_v1}
    @impl true
    def detect(_image, opts), do: {:ok, regions_for(opts)}

    defp regions_for(opts) do
      case Keyword.get(opts, :classes, :all) do
        :all -> @owned
        list -> Enum.filter(list, &(&1 in @owned))
      end
      |> Enum.map(&%{label: &1, score: 0.8, box: {50, 50, 10, 10}})
    end
  end

  defmodule ErroringChild do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["car"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(_), do: {__MODULE__, :err_v1}
    @impl true
    def detect(_image, _opts), do: {:error, {:detector, :boom}}
  end

  # Children that report which warmup ran, to verify class-routed warmup.
  defmodule WarmFace do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["face"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(_), do: {__MODULE__, :v}
    @impl true
    def detect(_, _), do: {:ok, []}
    @impl true
    def warmup(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:warmed, :face})
      :ok
    end
  end

  defmodule WarmObject do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["car"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(_), do: {__MODULE__, :v}
    @impl true
    def detect(_, _), do: {:ok, []}
    @impl true
    def warmup(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:warmed, :object})
      :ok
    end
  end

  defp composite, do: Composite.new([FaceChild, ObjectChild])

  test "warmup with a class list warms only the routed children" do
    composite = Composite.new([WarmFace, WarmObject])
    assert :ok = Composite.warmup(composite, classes: ["face"], test_pid: self())
    assert_received {:warmed, :face}
    refute_received {:warmed, :object}
  end

  test "warmup with :all warms every child" do
    composite = Composite.new([WarmFace, WarmObject])
    assert :ok = Composite.warmup(composite, classes: :all, test_pid: self())
    assert_received {:warmed, :face}
    assert_received {:warmed, :object}
  end

  test "surfaces the error when every routed child fails" do
    composite = Composite.new([ErroringChild])
    assert {:error, {:detector, :boom}} = Composite.detect(composite, :image, classes: ["car"])
  end

  test "best-effort: still succeeds when at least one routed child succeeds" do
    prefix = [__MODULE__, :partial_success]
    event = prefix ++ [:transform, :detect, :model, :stop]
    ref = :telemetry_test.attach_event_handlers(self(), [event])
    on_exit(fn -> :telemetry.detach(ref) end)

    # car routes to both ErroringChild (fails) and ObjectChild (succeeds)
    composite = Composite.new([ErroringChild, ObjectChild])

    assert {:ok, regions} =
             Composite.detect(composite, :image,
               classes: ["car"],
               telemetry_opts: [telemetry_prefix: prefix]
             )

    assert Enum.map(regions, & &1.label) == ["car"]
    assert_received {^event, ^ref, _, %{detector: ErroringChild, result: :error, regions: 0}}
    assert_received {^event, ^ref, _, %{detector: ObjectChild, result: :ok, regions: 1}}
  end

  test "supported_classes is the union of children" do
    assert Enum.sort(Composite.supported_classes(composite())) == ["car", "dog", "face"]
  end

  test ":all runs every child and merges all regions" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: :all)
    assert Enum.map(regions, & &1.label) |> Enum.sort() == ["car", "dog", "face"]
  end

  test "a class list routes only to the owning children" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["face", "car"])
    assert Enum.map(regions, & &1.label) |> Enum.sort() == ["car", "face"]
  end

  test "unknown classes are dropped (best-effort)" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["face", "unicorn"])
    assert Enum.map(regions, & &1.label) == ["face"]
  end

  test "all-unknown yields no regions and is available? = true (degrade, not fail)" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["unicorn"])
    assert regions == []
    assert Composite.available?(composite(), classes: ["unicorn"]) == true
  end

  test "identity reflects only routed children, ordered by child order" do
    assert Composite.identity(composite(), classes: ["face"]) ==
             {Composite, [{FaceChild, :face_v1}]}

    assert Composite.identity(composite(), classes: ["car"]) ==
             {Composite, [{ObjectChild, :obj_v1}]}

    # URL order invariance: face:dog vs dog:face produce the same identity list
    assert Composite.identity(composite(), classes: ["face", "dog"]) ==
             Composite.identity(composite(), classes: ["dog", "face"])

    assert Composite.identity(composite(), classes: :all) ==
             {Composite, [{FaceChild, :face_v1}, {ObjectChild, :obj_v1}]}
  end

  test "available? requires every routed child to be available" do
    c = composite()
    assert Composite.available?(c, classes: ["face"], object_available?: false) == true
    assert Composite.available?(c, classes: ["car"], object_available?: false) == false
    assert Composite.available?(c, classes: :all, object_available?: false) == false
  end

  test "emits a per-model span per routed child with detector, model identity, and classes" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:image_pipe, :transform, :detect, :model, :stop]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, _} =
      Composite.detect(composite(), :image,
        classes: ["face", "car"],
        telemetry_opts: [telemetry_prefix: [:image_pipe]]
      )

    assert_received {[:image_pipe, :transform, :detect, :model, :stop], ^ref, _measurements,
                     %{
                       detector: FaceChild,
                       model: {FaceChild, :face_v1},
                       classes: ["face"],
                       regions: 1
                     }}

    assert_received {[:image_pipe, :transform, :detect, :model, :stop], ^ref, _measurements,
                     %{
                       detector: ObjectChild,
                       model: {ObjectChild, :obj_v1},
                       classes: ["car"],
                       regions: 1
                     }}
  end
end
