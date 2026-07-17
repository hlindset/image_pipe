defmodule ImagePipe.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.KeyTest.ForwardingProbe
  alias ImagePipe.MaterialDigest
  alias ImagePipe.Parser.TwicPics
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform.NeutralResolver

  defp source_identity(overrides \\ []) do
    Keyword.merge(
      [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]],
      overrides
    )
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "cat.jpg"]},
          pipelines: [
            %Pipeline{
              operations: [resize_fit_operation(300, :auto)]
            },
            %Pipeline{
              operations: [crop_guided_operation(200, 100)]
            }
          ],
          output: %Output{mode: {:explicit, :webp}}
        ],
        overrides
      )
    )
  end

  defp build_key!(conn, plan, source_identity, opts \\ []) do
    assert {:ok, key} = Key.build(conn, plan, source_identity, opts)
    key
  end

  defp twic_plan!(chain) do
    {:ok, plan} =
      TwicPics.PlanBuilder.to_plan(
        %Source.Path{segments: ["images", "cat.jpg"]},
        chain,
        ImagePipe.Config.resolve!([])
      )

    plan
  end

  defp plan_with_resize_auto do
    plan(pipelines: [%Pipeline{operations: [resize_auto_operation(300, 200)]}])
  end

  defp resize_fit_operation(width, height, attrs \\ []) do
    operation_attrs =
      attrs
      |> Keyword.put_new(:enlargement, :deny)

    assert {:ok, operation} =
             Operation.resize(
               :fit,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               operation_attrs
             )

    operation
  end

  defp crop_guided_operation(width, height) do
    assert {:ok, operation} =
             Operation.crop_guided(tagged_dimension(width), tagged_dimension(height), :center)

    operation
  end

  defp detect_crop_operation(width, height) do
    assert {:ok, operation} =
             Operation.crop_guided(
               tagged_dimension(width),
               tagged_dimension(height),
               {:detect, {["face"], %{}}}
             )

    operation
  end

  defp detect_plan do
    plan(pipelines: [%Pipeline{operations: [detect_crop_operation(200, 100)]}])
  end

  defp face_assist_crop_operation(width, height) do
    assert {:ok, operation} =
             Operation.crop_guided(
               tagged_dimension(width),
               tagged_dimension(height),
               {:smart, :face_assist}
             )

    operation
  end

  defp face_assist_plan do
    plan(pipelines: [%Pipeline{operations: [face_assist_crop_operation(200, 100)]}])
  end

  defp resize_auto_operation(width, height) do
    assert {:ok, operation} =
             Operation.resize(
               :auto,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               dpr: 1.0,
               enlargement: :deny
             )

    operation
  end

  defp padding_operation(top, right, bottom, left, attrs) do
    assert {:ok, operation} =
             Operation.padding(
               {:px, top},
               {:px, right},
               {:px, bottom},
               {:px, left},
               attrs
             )

    operation
  end

  defp background_operation(red, green, blue, alpha) do
    assert {:ok, color} = Operation.color(red, green, blue, alpha)
    assert {:ok, operation} = Operation.background(color)
    operation
  end

  defp tagged_dimension(:auto), do: :full_axis
  defp tagged_dimension(pixels), do: {:px, pixels}
  defp tagged_resize_dimension(:auto), do: :auto
  defp tagged_resize_dimension(pixels), do: {:px, pixels}

  test "builds stable hash and key data from canonical plan fields and source identity" do
    conn = conn(:get, "/sig-one/w:100/plain/images/cat.jpg?ignored=true")

    key = build_key!(conn, plan(), source_identity())
    same = build_key!(conn, plan(), source_identity())
    different_source = build_key!(conn, plan(), Keyword.put(source_identity(), :root, "other"))

    assert key.hash == same.hash
    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/

    assert key.data == [
             schema_version: 2,
             source_identity: source_identity(),
             pipelines: [
               [
                 [
                   op: :resize,
                   mode: :fit,
                   width: [unit: :logical_px, value: 300],
                   height: [unit: :auto],
                   dpr: [unit: :ratio, numerator: 1, denominator: 1],
                   enlargement: :deny,
                   guide: :center,
                   x_offset: {:pixels, 0.0},
                   y_offset: {:pixels, 0.0},
                   min_width: nil,
                   min_height: nil,
                   max_width: nil,
                   max_height: nil,
                   max_area: nil,
                   zoom_x: 1.0,
                   zoom_y: 1.0
                 ]
               ],
               [
                 [
                   op: :crop_guided,
                   width: [unit: :logical_px, value: 200],
                   height: [unit: :logical_px, value: 100],
                   guide: :center,
                   x_offset: {:pixels, 0.0},
                   y_offset: {:pixels, 0.0},
                   aspect_ratio: nil,
                   enlarge: false
                 ]
               ]
             ],
             transform: [key_data_version: 1],
             resolver: [strategy: :neutral, version: 1],
             detector: nil,
             output: [
               mode: :explicit,
               format: :webp,
               quality: :default,
               format_qualities: %{},
               quality_search: :none,
               max_bytes: nil,
               strip_metadata: true,
               color_profile: :strip,
               keep_copyright: true,
               hdr: :tone_map,
               flatten_background: [
                 space: :srgb,
                 red: 255,
                 green: 255,
                 blue: 255,
                 alpha: [unit: :ratio, numerator: 1, denominator: 1]
               ],
               encoder_options: %{}
             ],
             auto_rotate: false,
             representation: [version: 1],
             cache: [cachebuster: nil],
             selected_headers: [],
             selected_cookies: []
           ]

    refute Keyword.has_key?(key.data, :origin_identity)
    refute inspect(key.data) =~ "sig-one"
    refute inspect(key.data) =~ "ignored=true"
    refute key.hash == different_source.hash
  end

  test "url_min_quality/url_max_quality are part of the quality_search cache key" do
    conn = conn(:get, "/_/plain/images/cat.jpg")
    base = %QualitySearch.Ssimulacra2{target: 78, min_quality: 70, max_quality: 80}

    k_plain =
      build_key!(
        conn,
        plan(output: %Output{mode: {:explicit, :webp}, quality_search: base}),
        source_identity()
      )

    k_url =
      build_key!(
        conn,
        plan(
          output: %Output{
            mode: {:explicit, :webp},
            quality_search: %{base | url_min_quality: 80, url_max_quality: 90}
          }
        ),
        source_identity()
      )

    refute k_plain.hash == k_url.hash
  end

  test "cache key contains representation version" do
    plan = plan(output: %Output{mode: {:explicit, :webp}})
    conn = conn(:get, "/image")

    key = build_key!(conn, plan, source_identity())

    assert key.data[:representation] == [version: Key.representation_version()]
  end

  test "cache key material excludes request safety limits" do
    conn = conn(:get, "/_/w:100/plain/images/cat.jpg")

    default_key =
      build_key!(
        conn,
        plan(),
        source_identity(),
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000,
        max_result_width: 8_192,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      )

    strict_key =
      build_key!(
        conn,
        plan(),
        source_identity(),
        max_body_bytes: 1_000_000,
        max_input_pixels: 1_000_000,
        max_result_width: 256,
        max_result_height: 256,
        max_result_pixels: 65_536
      )

    refute Keyword.has_key?(default_key.data, :request_limits)
    assert default_key.hash == strict_key.hash
  end

  test "cache lookup key is independent of request safety limits" do
    conn = conn(:get, "/_/w:100/plain/images/cat.jpg")
    plan = plan()
    identity = source_identity()

    loose =
      ImagePipe.Cache.lookup(conn, plan, identity,
        cache: {ForwardingProbe, test_pid: self()},
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000,
        max_result_width: 8_192,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      )

    assert {:miss, %Key{} = loose_key} = loose

    strict =
      ImagePipe.Cache.lookup(conn, plan, identity,
        cache: {ForwardingProbe, test_pid: self()},
        max_body_bytes: 1_000_000,
        max_input_pixels: 1_000_000,
        max_result_width: 256,
        max_result_height: 256,
        max_result_pixels: 65_536
      )

    assert {:miss, %Key{} = strict_key} = strict
    assert loose_key.hash == strict_key.hash
    refute Keyword.has_key?(loose_key.data, :request_limits)
  end

  test "source identity key data is product-neutral and independent of request URL" do
    conn_one = conn(:get, "/sig-one/w:100/plain/images/cat.jpg")
    conn_two = conn(:get, "/sig-two/width:100/plain/ignored/path.jpg?ignored=true")

    key_one = build_key!(conn_one, plan(), source_identity())
    key_two = build_key!(conn_two, plan(), source_identity())

    assert key_one.data[:source_identity] == source_identity()
    assert key_one.hash == key_two.hash
  end

  test "resolved source identity, not raw plan source spelling, drives source cache material" do
    conn_one = conn(:get, "/sig-one/plain/images/cat.jpg")
    conn_two = conn(:get, "/sig-two/plain/local:///images/cat.jpg")

    identity = [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]

    key_one =
      build_key!(
        conn_one,
        plan(source: %Source.Path{segments: ["images", "cat.jpg"]}),
        identity
      )

    key_two =
      build_key!(
        conn_two,
        plan(source: %Source.Path{segments: ["images", "cat.jpg"]}),
        identity
      )

    assert key_one.hash == key_two.hash
    assert key_one.data[:source_identity] == identity
  end

  test "pipelines key data preserves pipeline boundaries" do
    key =
      conn(:get, "/_/f:webp/plain/images/cat.jpg")
      |> build_key!(plan(), source_identity())

    assert key.data[:pipelines] == [
             [
               [
                 op: :resize,
                 mode: :fit,
                 width: [unit: :logical_px, value: 300],
                 height: [unit: :auto],
                 dpr: [unit: :ratio, numerator: 1, denominator: 1],
                 enlargement: :deny,
                 guide: :center,
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 min_width: nil,
                 min_height: nil,
                 max_width: nil,
                 max_height: nil,
                 max_area: nil,
                 zoom_x: 1.0,
                 zoom_y: 1.0
               ]
             ],
             [
               [
                 op: :crop_guided,
                 width: [unit: :logical_px, value: 200],
                 height: [unit: :logical_px, value: 100],
                 guide: :center,
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 aspect_ratio: nil,
                 enlarge: false
               ]
             ]
           ]
  end

  test "pipelines key data uses canonical operations instead of raw transform tuples or structs" do
    key =
      conn(:get, "/_/f:webp/plain/images/cat.jpg")
      |> build_key!(plan(), source_identity())

    refute inspect(key.data[:pipelines]) =~ "ImagePipe.Transform"

    assert key.data[:pipelines]
           |> Enum.flat_map(& &1)
           |> Enum.all?(&Keyword.keyword?/1)
  end

  test "unified resize operation contributes prefetch-safe cache key data" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 300}, {:px, 200},
               dpr: "1.00",
               enlargement: :deny
             )

    key =
      conn(:get, "/_/rt:auto/w:300/h:200/f:webp/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [operation]}]),
        source_identity()
      )

    assert key.data[:pipelines] == [
             [
               [
                 op: :resize,
                 mode: :auto,
                 width: [unit: :logical_px, value: 300],
                 height: [unit: :logical_px, value: 200],
                 dpr: [unit: :ratio, numerator: 1, denominator: 1],
                 enlargement: :deny,
                 guide: :center,
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 min_width: nil,
                 min_height: nil,
                 max_width: nil,
                 max_height: nil,
                 max_area: nil,
                 zoom_x: 1.0,
                 zoom_y: 1.0,
                 rule: :auto_orientation_match_v1
               ]
             ]
           ]

    refute inspect(key.data[:pipelines]) =~ "selected_branch"
    refute inspect(key.data[:pipelines]) =~ "resize_auto"
  end

  test "crop operations contribute prefetch-safe cache key data" do
    assert {:ok, guided} =
             Operation.crop_guided({:px, 120}, :full_axis, :bottom_right, x_offset: {:pixels, 3})

    assert {:ok, region} =
             Operation.crop_region({:px, 0}, {:ratio, 0, 1}, {:ratio, 1, 2}, {:px, 80})

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [guided, region]}]),
        source_identity()
      )

    assert key.data[:pipelines] == [
             [
               [
                 op: :crop_guided,
                 width: [unit: :logical_px, value: 120],
                 height: [unit: :full_axis],
                 guide: :bottom_right,
                 x_offset: {:pixels, 3},
                 y_offset: {:pixels, 0.0},
                 aspect_ratio: nil,
                 enlarge: false
               ],
               [
                 op: :crop_region,
                 x: [unit: :logical_px, value: 0],
                 y: [unit: :ratio, numerator: 0, denominator: 1],
                 width: [unit: :ratio, numerator: 1, denominator: 2],
                 height: [unit: :logical_px, value: 80],
                 on_out_of_bounds: :clamp
               ]
             ]
           ]
  end

  test "resize key data includes requested zoom and dpr rule inputs" do
    operation = resize_fit_operation(100, :auto, dpr: 2.0, zoom_x: 2.0, zoom_y: 1.5)

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [operation]}]),
        source_identity()
      )

    assert [[resize_data]] = key.data[:pipelines]
    assert resize_data[:op] == :resize
    assert resize_data[:mode] == :fit
    assert resize_data[:dpr] == [unit: :ratio, numerator: 2, denominator: 1]
    assert resize_data[:zoom_x] == 2.0
    assert resize_data[:zoom_y] == 1.5
  end

  test "resize auto cache key data stays unresolved and source-metadata-free" do
    operation = resize_auto_operation(300, 200)

    semantic_plan = plan(pipelines: [%Pipeline{operations: [operation]}])
    conn = conn(:get, "/_/rt:auto/w:300/h:200/f:jpeg/plain/images/cat.jpg")

    key_a = build_key!(conn, semantic_plan, source_identity(revision: "a"))
    key_b = build_key!(conn, semantic_plan, source_identity(revision: "b"))

    assert [[key_data]] = key_a.data[:pipelines]

    assert key_data == [
             op: :resize,
             mode: :auto,
             width: [unit: :logical_px, value: 300],
             height: [unit: :logical_px, value: 200],
             dpr: [unit: :ratio, numerator: 1, denominator: 1],
             enlargement: :deny,
             guide: :center,
             x_offset: {:pixels, 0.0},
             y_offset: {:pixels, 0.0},
             min_width: nil,
             min_height: nil,
             max_width: nil,
             max_height: nil,
             max_area: nil,
             zoom_x: 1.0,
             zoom_y: 1.0,
             rule: :auto_orientation_match_v1
           ]

    serialized = inspect(key_a.data, limit: :infinity)
    refute Keyword.has_key?(key_data, :selected_branch)
    refute serialized =~ "source_width"
    refute serialized =~ "source_height"
    refute serialized =~ "selected_branch"
    refute key_a.hash == key_b.hash
  end

  test "unified resize offsets participate in cache key data" do
    assert {:ok, no_offset} = Operation.resize(:cover, {:px, 300}, {:px, 200})

    assert {:ok, with_offset} =
             Operation.resize(:cover, {:px, 300}, {:px, 200},
               x_offset: {:pixels, 12.0},
               y_offset: {:scale, -0.25}
             )

    conn = conn(:get, "/_/rs:fill:300:200/f:jpeg/plain/images/cat.jpg")

    no_offset_key =
      build_key!(
        conn,
        plan(pipelines: [%Pipeline{operations: [no_offset]}]),
        source_identity()
      )

    with_offset_key =
      build_key!(
        conn,
        plan(pipelines: [%Pipeline{operations: [with_offset]}]),
        source_identity()
      )

    assert [[resize_data]] = with_offset_key.data[:pipelines]
    assert resize_data[:x_offset] == {:pixels, 12.0}
    assert resize_data[:y_offset] == {:scale, -0.25}
    refute no_offset_key.data[:pipelines] == with_offset_key.data[:pipelines]
  end

  test "post-fetch resize auto branch is not accepted as final output cache key input" do
    conn = conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg")
    key_before = build_key!(conn, plan_with_resize_auto(), source_identity(revision: "v1"))

    key_after_resolve = build_key!(conn, plan_with_resize_auto(), source_identity(revision: "v1"))
    serialized = inspect(key_before.data, limit: :infinity)

    assert key_before == key_after_resolve
    assert [[key_data]] = key_before.data[:pipelines]
    assert key_data[:op] == :resize
    assert key_data[:mode] == :auto
    refute Keyword.has_key?(key_data, :selected_branch)
    refute Keyword.has_key?(key_data, :branch)
    refute serialized =~ "resize_auto_branch"
    refute serialized =~ "selected_branch"
    refute Keyword.has_key?(key_before.data, :derivations)
  end

  test "cache key builder accepts semantic plans" do
    key =
      build_key!(
        conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg"),
        plan_with_resize_auto(),
        source_identity(revision: "v1")
      )

    assert key.data[:pipelines]
  end

  test "source freshness identity changes cache key without changing semantic key data" do
    conn = conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg")
    semantic_plan = plan_with_resize_auto()

    key_a = build_key!(conn, semantic_plan, source_identity(revision: "cat-v1"))
    key_a_same = build_key!(conn, semantic_plan, source_identity(revision: "cat-v1"))
    key_b = build_key!(conn, semantic_plan, source_identity(revision: "cat-v2"))

    assert key_a.hash == key_a_same.hash
    assert key_a.data[:pipelines] == key_b.data[:pipelines]
    refute key_a.hash == key_b.hash
  end

  test "composition operations contribute canonical cache key data" do
    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> build_key!(
        plan(
          pipelines: [
            %Pipeline{
              operations: [
                padding_operation(1, 2, 3, 4, pixel_ratio: {:ratio, 3, 2}),
                background_operation(255, 0, 0, {:ratio, 1, 2})
              ]
            }
          ]
        ),
        source_identity()
      )

    assert key.data[:transform] == [key_data_version: 1]

    assert key.data[:pipelines] == [
             [
               [
                 op: :padding,
                 top: [unit: :logical_px, value: 1],
                 right: [unit: :logical_px, value: 2],
                 bottom: [unit: :logical_px, value: 3],
                 left: [unit: :logical_px, value: 4],
                 pixel_ratio: [unit: :ratio, numerator: 3, denominator: 2],
                 fill: :transparent
               ],
               [
                 op: :background,
                 color: [
                   space: :srgb,
                   red: 255,
                   green: 0,
                   blue: 0,
                   alpha: [unit: :ratio, numerator: 1, denominator: 2]
                 ]
               ]
             ]
           ]
  end

  test "dimension spellings that fold to the same canonical plan produce identical cache keys" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    plan_a = twic_plan!([{"resize", "100x100"}])
    plan_b = twic_plan!([{"resize", "(50*2)x100"}])

    key_a = build_key!(conn, plan_a, source_identity())
    key_b = build_key!(conn, plan_b, source_identity())

    assert key_a.data[:pipelines] == key_b.data[:pipelines]
    assert key_a.hash == key_b.hash
  end

  test "ratio spellings that reduce to the same canonical plan produce identical cache keys" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    plan_a = twic_plan!([{"cover", "1:1"}])
    plan_b = twic_plan!([{"cover", "2:2"}])

    key_a = build_key!(conn, plan_a, source_identity())
    key_b = build_key!(conn, plan_b, source_identity())

    assert key_a.data[:pipelines] == key_b.data[:pipelines]
    assert key_a.hash == key_b.hash
  end

  test "detect plans key differently per detector identity" do
    conn = conn(:get, "/_/g:obj:face/w:200/h:100/plain/images/cat.jpg")
    plan = detect_plan()

    k1 = build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v1})
    k2 = build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v2})

    refute k1.hash == k2.hash
  end

  test "canonically-equal detect weights produce the same cache key" do
    conn = conn(:get, "/_/g:objw:all:1:face:3/w:200/h:100/plain/images/cat.jpg")

    {:ok, op} =
      Operation.crop_guided(
        tagged_dimension(200),
        tagged_dimension(100),
        {:detect, {:all, %{"face" => 3.0}}}
      )

    p = plan(pipelines: [%Pipeline{operations: [op]}])

    k1 = build_key!(conn, p, source_identity(), detector_identity: {Detector, :v1})
    k2 = build_key!(conn, p, source_identity(), detector_identity: {Detector, :v1})

    assert k1.hash == k2.hash
  end

  test "different detect weights produce different cache keys" do
    conn = conn(:get, "/_/g:objw:all:1:face:3/w:200/h:100/plain/images/cat.jpg")

    plan_for = fn weights ->
      {:ok, op} =
        Operation.crop_guided(
          tagged_dimension(200),
          tagged_dimension(100),
          {:detect, {:all, weights}}
        )

      plan(pipelines: [%Pipeline{operations: [op]}])
    end

    k1 =
      build_key!(conn, plan_for.(%{"face" => 3.0}), source_identity(),
        detector_identity: {Detector, :v1}
      )

    k2 =
      build_key!(conn, plan_for.(%{"face" => 2.0}), source_identity(),
        detector_identity: {Detector, :v1}
      )

    refute k1.hash == k2.hash
  end

  test "face-assist plans key differently per detector identity" do
    conn = conn(:get, "/_/g:sm/w:200/h:100/plain/images/cat.jpg")
    plan = face_assist_plan()

    k1 = build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v1})
    k2 = build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v2})

    refute k1.hash == k2.hash
  end

  test "unavailable detector identity keys differently from a present one" do
    conn = conn(:get, "/_/g:obj:face/w:200/h:100/plain/images/cat.jpg")
    plan = detect_plan()

    present = build_key!(conn, plan, source_identity(), detector_identity: {Detector, {"r", "f"}})

    absent =
      build_key!(conn, plan, source_identity(), detector_identity: {Detector, :unavailable})

    refute present.hash == absent.hash
  end

  test "transform key data version participates in the cache key" do
    conn = conn(:get, "/_/plain/images/cat.jpg")
    key = build_key!(conn, plan(), source_identity())
    changed_data = Keyword.put(key.data, :transform, key_data_version: 2)
    assert key.data[:transform] == [key_data_version: 1]

    refute key.hash == Base.encode16(MaterialDigest.of(changed_data), case: :lower)
  end

  test "cache key construction does not reference source-aware resolution" do
    source =
      __DIR__
      |> Path.join("../../../lib/image_pipe/cache/key.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "Transform.resolve"
    refute source =~ "SourceMetadata"
    refute source =~ "source_width"
    refute source =~ "source_height"
  end

  test "cachebuster changes cache keys without changing pipeline key data" do
    base_plan = plan()
    busted_plan = plan(cachebuster: "v2")

    conn = conn(:get, "/_/plain/images/cat.jpg")
    base = build_key!(conn, base_plan, source_identity())
    busted = build_key!(conn, busted_plan, source_identity())

    assert base.data[:pipelines] == busted.data[:pipelines]
    assert busted.data[:cache] == [cachebuster: "v2"]
    refute base.hash == busted.hash
  end

  test "auto_rotate participates in the cache key" do
    conn = conn(:get, "/_/plain/images/cat.jpg")
    off = build_key!(conn, plan(auto_rotate: false), source_identity())
    on = build_key!(conn, plan(auto_rotate: true), source_identity())
    assert off.data[:auto_rotate] == false
    assert on.data[:auto_rotate] == true
    refute off.hash == on.hash
  end

  test "flatten_background participates in the cache key" do
    conn = conn(:get, "/_/plain/images/cat.jpg")
    {:ok, red} = Color.rgb(255, 0, 0)

    white = build_key!(conn, plan(output: %Output{mode: {:explicit, :jpeg}}), source_identity())

    red_key =
      build_key!(
        conn,
        plan(output: %Output{mode: {:explicit, :jpeg}, flatten_background: red}),
        source_identity()
      )

    assert white.data[:output][:flatten_background] ==
             Color.key_data(Color.white())

    assert red_key.data[:output][:flatten_background] == Color.key_data(red)
    refute white.hash == red_key.hash
  end

  test "response delivery metadata is excluded from cache key data" do
    one = plan(response: %ImagePipe.Plan.Response{disposition: :attachment})
    two = plan(response: %ImagePipe.Plan.Response{disposition: :inline})

    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert build_key!(conn, one, source_identity()).hash ==
             build_key!(conn, two, source_identity()).hash
  end

  test "requests differing only by filename share cache key data" do
    one =
      plan(
        response: %ImagePipe.Plan.Response{
          disposition: :attachment,
          filename: "one"
        }
      )

    two =
      plan(
        response: %ImagePipe.Plan.Response{
          disposition: :inline,
          filename: "two"
        }
      )

    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert build_key!(conn, one, source_identity()).hash ==
             build_key!(conn, two, source_identity()).hash
  end

  test "output key data includes normalized quality rules" do
    output = %Output{
      mode: :automatic,
      quality: :default,
      format_qualities: %{webp: {:quality, 70}}
    }

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp")
      |> build_key!(plan(output: output), source_identity())

    assert key.data[:output][:quality] == :default
    assert key.data[:output][:format_qualities] == %{webp: {:quality, 70}}
  end

  test "automatic output includes modern candidates instead of selected output or raw Accept" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    key_one = build_key!(conn_one, automatic_plan, source_identity())
    key_two = build_key!(conn_two, automatic_plan, source_identity())

    assert key_one.data[:output] == [
             mode: :automatic,
             modern_candidates: [:avif, :webp],
             auto: [jpeg_xl: true, avif: true, webp: true],
             quality: :default,
             format_qualities: %{},
             quality_search: :none,
             max_bytes: nil,
             strip_metadata: true,
             color_profile: :strip,
             keep_copyright: true,
             hdr: :tone_map,
             flatten_background: [
               space: :srgb,
               red: 255,
               green: 255,
               blue: 255,
               alpha: [unit: :ratio, numerator: 1, denominator: 1]
             ],
             encoder_options: %{}
           ]

    refute inspect(key_one.data) =~ "image/webp"
    refute inspect(key_one.data) =~ "image/avif"
    assert key_one.hash == key_two.hash
  end

  test "automatic output normalizes missing empty and wildcard-only Accept to no modern candidates" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    keys =
      [
        conn(:get, "/_/plain/images/cat.jpg"),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", ""),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", "*/*"),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", "*/*;q=1"),
        conn(:get, "/_/plain/images/cat.jpg")
        |> put_req_header("accept", "application/json,*/*;q=1")
      ]
      |> Enum.map(&build_key!(&1, automatic_plan, source_identity()))

    assert Enum.map(keys, & &1.hash) |> Enum.uniq() |> length() == 1

    for key <- keys do
      assert key.data[:output] == [
               mode: :automatic,
               modern_candidates: [],
               auto: [jpeg_xl: true, avif: true, webp: true],
               quality: :default,
               format_qualities: %{},
               quality_search: :none,
               max_bytes: nil,
               strip_metadata: true,
               color_profile: :strip,
               keep_copyright: true,
               hdr: :tone_map,
               flatten_background: [
                 space: :srgb,
                 red: 255,
                 green: 255,
                 blue: 255,
                 alpha: [unit: :ratio, numerator: 1, denominator: 1]
               ],
               encoder_options: %{}
             ]

      refute inspect(key.data) =~ "*/*"
      refute inspect(key.data) =~ "application/json"
    end
  end

  test "different automatic Accept capabilities change cache key" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    avif_key =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif")
      |> build_key!(automatic_plan, source_identity())

    webp_key =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp")
      |> build_key!(automatic_plan, source_identity())

    refute avif_key.hash == webp_key.hash
  end

  test "different automatic output feature flags change cache key" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    default_key = build_key!(conn, automatic_plan, source_identity())

    webp_only_key =
      build_key!(conn, automatic_plan, source_identity(), auto_avif: false)

    refute default_key.hash == webp_only_key.hash

    assert webp_only_key.data[:output] == [
             mode: :automatic,
             modern_candidates: [:webp],
             auto: [jpeg_xl: true, avif: false, webp: true],
             quality: :default,
             format_qualities: %{},
             quality_search: :none,
             max_bytes: nil,
             strip_metadata: true,
             color_profile: :strip,
             keep_copyright: true,
             hdr: :tone_map,
             flatten_background: [
               space: :srgb,
               red: 255,
               green: 255,
               blue: 255,
               alpha: [unit: :ratio, numerator: 1, denominator: 1]
             ],
             encoder_options: %{}
           ]
  end

  test "disabling auto_jpeg_xl changes the cache key and drops jpeg_xl from candidates" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jxl,image/avif")

    caps = [output_capabilities: %{jpeg_xl: true, avif: true}]

    default_key = build_key!(conn, automatic_plan, source_identity(), caps)

    no_jxl_key =
      build_key!(conn, automatic_plan, source_identity(), [auto_jpeg_xl: false] ++ caps)

    refute default_key.hash == no_jxl_key.hash

    assert default_key.data[:output][:modern_candidates] == [:avif, :jpeg_xl]
    assert no_jxl_key.data[:output][:modern_candidates] == [:avif]
    assert no_jxl_key.data[:output][:auto][:jpeg_xl] == false
  end

  test "every Plan.Output field is accounted for in the cache key (drift guard)" do
    # Fields whose key contribution is carried elsewhere or deliberately excluded,
    # each with a rationale. Adding a Plan.Output field forces a decision here so a
    # byte-affecting field can never silently miss the key (and the ETag).
    excluded = %{
      # `mode` selects the :automatic/:explicit key-data clause, not a field value.
      mode: "drives key-data clause selection",
      # offsets only bias the search ESTIMATE; the resolved searched quality is what
      # changes bytes and is already keyed via quality_search.
      quality_search_offsets: "subsumed by the resolved quality_search",
      # the global default only seeds quality resolution; its byte effect is carried
      # into the key by the resolved quality / format_qualities, never independently.
      default_quality: "subsumed by resolved quality/format_qualities"
    }

    conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")

    keyed =
      conn
      |> build_key!(plan(output: %Output{mode: {:explicit, :webp}}), source_identity())
      |> Map.fetch!(:data)
      |> Keyword.fetch!(:output)
      |> Keyword.keys()
      |> MapSet.new()

    for {field, _} <- Map.from_struct(%Output{mode: :automatic}) do
      assert MapSet.member?(keyed, field) or Map.has_key?(excluded, field),
             "Plan.Output field #{inspect(field)} is neither in the cache key nor in the " <>
               "excluded-with-rationale list. Add it to output_plan_data/2 or document why it " <>
               "does not affect stored bytes."
    end
  end

  test "different encoder options change the cache key (and do not crash)" do
    conn = conn(:get, "/_/f:jxl/plain/images/cat.jpg")

    key_a =
      build_key!(
        conn,
        plan(
          output: %Output{
            mode: {:explicit, :jpeg_xl},
            encoder_options: %{jpeg_xl: %ImagePipe.Plan.Output.JxlOptions{effort: 7}}
          }
        ),
        source_identity()
      )

    key_b =
      build_key!(
        conn,
        plan(
          output: %Output{
            mode: {:explicit, :jpeg_xl},
            encoder_options: %{jpeg_xl: %ImagePipe.Plan.Output.JxlOptions{effort: 4}}
          }
        ),
        source_identity()
      )

    refute key_a.hash == key_b.hash, "expected differing encoder options to change the cache key"
  end

  test "identical encoder options yield identical keys" do
    conn = conn(:get, "/_/f:jpg/plain/images/cat.jpg")

    opts = %{jpeg: %ImagePipe.Plan.Output.JpegOptions{interlace: true}}

    key_a =
      build_key!(
        conn,
        plan(output: %Output{mode: {:explicit, :jpeg}, encoder_options: opts}),
        source_identity()
      )

    key_b =
      build_key!(
        conn,
        plan(output: %Output{mode: {:explicit, :jpeg}, encoder_options: opts}),
        source_identity()
      )

    assert key_a.hash == key_b.hash
  end

  test "different output metadata flags change cache key" do
    conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")

    for flag <- [:strip_metadata, :keep_copyright] do
      on_plan = plan(output: %Output{mode: {:explicit, :webp}} |> Map.put(flag, true))
      off_plan = plan(output: %Output{mode: {:explicit, :webp}} |> Map.put(flag, false))

      on_key = build_key!(conn, on_plan, source_identity())
      off_key = build_key!(conn, off_plan, source_identity())

      refute on_key.hash == off_key.hash,
             "expected differing #{flag} to change the cache key"
    end

    strip_key =
      build_key!(
        conn,
        plan(output: %Output{mode: {:explicit, :webp}, color_profile: :strip}),
        source_identity()
      )

    preserve_key =
      build_key!(
        conn,
        plan(output: %Output{mode: {:explicit, :webp}, color_profile: :preserve_source}),
        source_identity()
      )

    refute strip_key.hash == preserve_key.hash,
           "expected differing color_profile to change the cache key"
  end

  test "explicit formats do not include Accept key data or automatic marker" do
    conn =
      :get
      |> conn("/_/f:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = build_key!(conn, plan(), source_identity())

    assert key.data[:output] == [
             mode: :explicit,
             format: :webp,
             quality: :default,
             format_qualities: %{},
             quality_search: :none,
             max_bytes: nil,
             strip_metadata: true,
             color_profile: :strip,
             keep_copyright: true,
             hdr: :tone_map,
             flatten_background: [
               space: :srgb,
               red: 255,
               green: 255,
               blue: 255,
               alpha: [unit: :ratio, numerator: 1, denominator: 1]
             ],
             encoder_options: %{}
           ]

    refute inspect(key.data) =~ "image/jpeg"
  end

  test "only configured headers and cookies are included" do
    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("x-ignored", "ignored")
      |> put_req_header("cookie", "tenant=acme; ignored_cookie=ignored")

    key =
      build_key!(conn, plan(), source_identity(),
        key_headers: ["Accept-Language"],
        key_cookies: ["tenant"]
      )

    assert key.data[:selected_headers] == [{"accept-language", ["en-US"]}]
    assert key.data[:selected_cookies] == [{"tenant", "acme"}]
    refute inspect(key.data) =~ "x-ignored"
    refute inspect(key.data) =~ "ignored_cookie"
  end

  describe "TwicPics carried focus (#321)" do
    # The cache-key / ETag fast path (Key.plan_material -> KeyData.data per op) must
    # handle the :deferred guide and %Directive{} ops the TwicPics parser now emits.
    # The default guide is :deferred, so even a focus-less cover exercises it.
    test "plan_material handles a carried cover with no focus segment" do
      assert {:ok, _material} = Key.plan_material(twic_plan!([{"cover", "100x100"}]), [])
    end

    test "plan_material keys the set_focus directive payload in a coordinate-focus plan" do
      assert {:ok, material} =
               Key.plan_material(twic_plan!([{"focus", "20x10"}, {"crop", "12x12"}]), [])

      assert inspect(material) =~ "name: :set_focus"
    end

    test "distinct focus points produce distinct key material" do
      {:ok, a} = Key.plan_material(twic_plan!([{"focus", "20x10"}, {"crop", "12x12"}]), [])
      {:ok, b} = Key.plan_material(twic_plan!([{"focus", "30x10"}, {"crop", "12x12"}]), [])
      refute a == b
    end
  end

  describe "quality_search / max_bytes in the cache key (#344)" do
    defp qs_output(overrides) do
      struct!(%Output{mode: :automatic}, overrides)
    end

    defp qs_search(overrides) do
      struct!(
        %QualitySearch.Ssimulacra2{target: 90.0, min_quality: 70, max_quality: 80},
        overrides
      )
    end

    defp qs_key_for(output) do
      conn(:get, "/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp")
      |> build_key!(plan(output: output), source_identity())
    end

    defp qs_etag_for(output) do
      {:ok, material} = Key.plan_material(plan(output: output), [])
      material[:output]
    end

    test "different max_bytes targets do not collide" do
      refute qs_key_for(qs_output(max_bytes: 50_000)).hash ==
               qs_key_for(qs_output(max_bytes: 60_000)).hash
    end

    test "different ssim2 targets do not collide" do
      refute qs_key_for(qs_output(quality_search: qs_search(target: 90.0))).hash ==
               qs_key_for(qs_output(quality_search: qs_search(target: 85.0))).hash
    end

    test "semantically identical searches reuse the same key" do
      assert qs_key_for(qs_output(quality_search: qs_search(target: 90.0))).hash ==
               qs_key_for(qs_output(quality_search: qs_search(target: 90.0))).hash
    end

    test "canonically-equal per-format clamps reuse the same key" do
      a = qs_search(format_min: %{webp: 60, jpeg: 50}, format_max: %{webp: 90})
      b = qs_search(format_min: %{jpeg: 50, webp: 60}, format_max: %{webp: 90})

      assert qs_key_for(qs_output(quality_search: a)).hash ==
               qs_key_for(qs_output(quality_search: b)).hash
    end

    test "max_resolution enters the key (it selects which bytes are stored)" do
      refute qs_key_for(qs_output(quality_search: qs_search(max_resolution: 0))).hash ==
               qs_key_for(qs_output(quality_search: qs_search(max_resolution: 50))).hash
    end

    test "different max_bytes targets yield different ETag material" do
      refute qs_etag_for(qs_output(max_bytes: 50_000)) ==
               qs_etag_for(qs_output(max_bytes: 60_000))
    end

    test "max_resolution enters the ETag material (it selects which bytes are stored)" do
      refute qs_etag_for(qs_output(quality_search: qs_search(max_resolution: 0))) ==
               qs_etag_for(qs_output(quality_search: qs_search(max_resolution: 50)))
    end

    test "ssim2 and butteraugli searches at the same numeric target produce distinct keys" do
      ssim2 = %QualitySearch.Ssimulacra2{
        target: 1.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 0.1
      }

      butter = %QualitySearch.Butteraugli{
        target: 1.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 0.1
      }

      refute qs_key_for(qs_output(quality_search: ssim2)).hash ==
               qs_key_for(qs_output(quality_search: butter)).hash
    end
  end

  describe "plan_material resolver tag" do
    test "a nil-resolver plan tags the neutral strategy" do
      {:ok, material} = Key.plan_material(plan(), [])

      assert material[:resolver] == [
               strategy: :neutral,
               version: NeutralResolver.behavior_version()
             ]
    end

    test "a strategy-carrying plan tags the module and its behavioral version" do
      plan = %{plan() | resolver: NeutralResolver}
      {:ok, material} = Key.plan_material(plan, [])

      assert material[:resolver] == [
               strategy: NeutralResolver,
               version: NeutralResolver.behavior_version()
             ]
    end

    test "a dialect-carrying plan tags that strategy and its behavioral version" do
      plan = %{plan() | resolver: TwicPics.Resolver}
      {:ok, material} = Key.plan_material(plan, [])

      assert material[:resolver] == [
               strategy: TwicPics.Resolver,
               version: TwicPics.Resolver.behavior_version()
             ]
    end
  end
end
