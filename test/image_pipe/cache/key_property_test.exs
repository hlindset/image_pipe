defmodule ImagePipe.Cache.KeyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Key
  alias ImagePipe.Format
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  defp build_key!(conn, plan, source_identity, opts \\ []) do
    assert {:ok, key} = Key.build(conn, plan, source_identity, opts)
    key
  end

  property "cache key serialization is deterministic for canonical key data" do
    check all key_data <- key_data(),
              max_runs: 100 do
      assert Key.serialize_key_data(key_data) == Key.serialize_key_data(key_data)
    end
  end

  property "nested map and keyword ordering does not affect serialized key data" do
    check all source_identity <- source_identity(),
              source_path <- source_path(),
              width <- maybe_dimension(),
              height <- maybe_dimension(),
              max_runs: 100 do
      data_one = [
        schema_version: 2,
        source_identity: [
          identity: source_identity,
          kind: :plain,
          path: source_path,
          nested: [
            map: %{b: 2, a: 1},
            keyword: [b: 2, a: 1]
          ]
        ],
        pipelines: [
          [
            [
              op: :contain,
              width: width,
              height: height,
              constraint: :max,
              letterbox: false
            ]
          ]
        ],
        output: [
          mode: :explicit,
          format: :webp,
          quality: :default,
          format_qualities: %{}
        ],
        cache: [cachebuster: nil],
        selected_headers: [],
        selected_cookies: []
      ]

      data_two = [
        selected_cookies: [],
        selected_headers: [],
        output: [
          format_qualities: %{},
          quality: :default,
          format: :webp,
          mode: :explicit
        ],
        cache: [cachebuster: nil],
        pipelines: [
          [
            [
              letterbox: false,
              constraint: :max,
              height: height,
              width: width,
              op: :contain
            ]
          ]
        ],
        source_identity: [
          nested: [
            keyword: [a: 1, b: 2],
            map: %{a: 1, b: 2}
          ],
          path: source_path,
          kind: :plain,
          identity: source_identity
        ],
        schema_version: 2
      ]

      assert Key.serialize_key_data(data_one) == Key.serialize_key_data(data_two)
    end
  end

  property "request URL, ignored headers, and ignored cookies do not affect plan cache keys" do
    check all plan <- cacheable_plan(),
              signature <- string(:alphanumeric, min_length: 1, max_length: 24),
              query <- string(:alphanumeric, max_length: 24),
              ignored_header_value <- string(:alphanumeric, max_length: 24),
              ignored_cookie_value <- string(:alphanumeric, max_length: 24),
              max_runs: 100 do
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      conn_one = conn(:get, "/_/plain/images/cat.jpg")

      conn_two =
        :get
        |> conn("/#{signature}/plain/changed/path.jpg?#{query}")
        |> put_req_header("x-ignored", ignored_header_value)
        |> put_req_header("cookie", "ignored=#{ignored_cookie_value}")

      assert build_key!(conn_one, plan, source_identity).hash ==
               build_key!(conn_two, plan, source_identity).hash
    end
  end

  property "included source identity and output format change the cache key" do
    check all plan <- cacheable_plan(output: %Output{mode: {:explicit, :webp}}),
              source_identity_a <- source_identity(),
              source_identity_b <- source_identity(),
              source_identity_a != source_identity_b,
              max_runs: 100 do
      conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")

      source_key_a = build_key!(conn, plan, source_identity_a)
      source_key_b = build_key!(conn, plan, source_identity_b)

      png_key =
        build_key!(conn, %{plan | output: %Output{mode: {:explicit, :png}}}, source_identity_a)

      refute source_key_a.hash == source_key_b.hash
      refute source_key_a.hash == png_key.hash
    end
  end

  property "pipeline boundaries affect the cache key" do
    check all operation_a <- operation(),
              operation_b <- operation(),
              max_runs: 100 do
      one_pipeline =
        plan(pipelines: [%Pipeline{operations: [operation_a, operation_b]}])

      two_pipelines =
        plan(
          pipelines: [%Pipeline{operations: [operation_a]}, %Pipeline{operations: [operation_b]}]
        )

      conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      refute build_key!(conn, one_pipeline, source_identity).hash ==
               build_key!(conn, two_pipelines, source_identity).hash
    end
  end

  property "cachebuster changes cache keys without changing pipeline key data" do
    check all cachebuster_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              cachebuster_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              cachebuster_a != cachebuster_b,
              max_runs: 100 do
      conn = conn(:get, "/_/plain/images/cat.jpg")
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      key_a =
        build_key!(
          conn,
          plan(cachebuster: cachebuster_a),
          source_identity
        )

      key_b =
        build_key!(
          conn,
          plan(cachebuster: cachebuster_b),
          source_identity
        )

      assert key_a.data[:pipelines] == key_b.data[:pipelines]
      refute key_a.hash == key_b.hash
    end
  end

  property "selected headers affect the cache key when configured" do
    check all header_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_a != header_value_b,
              cookie_value <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 100 do
      plan = plan()
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      conn_a =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value_a)
        |> put_req_header("cookie", "tenant=#{cookie_value}")

      conn_b =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value_b)
        |> put_req_header("cookie", "tenant=#{cookie_value}")

      opts = [key_headers: ["accept-language"], key_cookies: ["tenant"]]

      refute build_key!(conn_a, plan, source_identity, opts).hash ==
               build_key!(conn_b, plan, source_identity, opts).hash
    end
  end

  property "selected cookies affect the cache key when configured" do
    check all cookie_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_a != cookie_value_b,
              header_value <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 100 do
      plan = plan()
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      conn_a =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value)
        |> put_req_header("cookie", "tenant=#{cookie_value_a}")

      conn_b =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value)
        |> put_req_header("cookie", "tenant=#{cookie_value_b}")

      opts = [key_headers: ["accept-language"], key_cookies: ["tenant"]]

      refute build_key!(conn_a, plan, source_identity, opts).hash ==
               build_key!(conn_b, plan, source_identity, opts).hash
    end
  end

  property "raw Accept headers with the same normalized class produce the same automatic key" do
    check all {accept_a, accept_b} <-
                member_of([
                  {"image/avif,image/webp", "image/webp;q=1,image/avif;q=0.1"},
                  {"image/jpeg", "image/jpg"},
                  {"image/avif;q=0,image/*", "image/*,image/avif;q=0"}
                ]),
              max_runs: 100 do
      plan = plan(output: %Output{mode: :automatic})
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_a)
        |> build_key!(plan, source_identity)

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_b)
        |> build_key!(plan, source_identity)

      assert key_a.hash == key_b.hash
    end
  end

  property "different normalized Accept classes change automatic cache key" do
    check all {accept_a, accept_b} <-
                member_of([
                  {"image/avif", "image/webp"},
                  {"image/avif", "image/jpeg"},
                  {"image/webp", "image/jpeg"},
                  {"image/avif,image/*", "image/*"},
                  {"image/avif", "image/avif;q=0,image/*"}
                ]),
              max_runs: 100 do
      plan = plan(output: %Output{mode: :automatic})
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_a)
        |> build_key!(plan, source_identity)

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_b)
        |> build_key!(plan, source_identity)

      refute key_a.hash == key_b.hash
    end
  end

  property "automatic cache key does not depend on runtime-selected source fallback format" do
    check all accept <- accept_header(),
              max_runs: 100 do
      plan = plan(output: %Output{mode: :automatic})
      source_identity = [kind: :path, root: "default", path: ["images", "cat.jpg"]]

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(plan, source_identity)

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(plan, source_identity)

      assert key_a.hash == key_b.hash
    end
  end

  defp key_data do
    map(
      {source_identity(), source_path(), pipelines(),
       member_of([:automatic | Format.output_formats()])},
      fn {source_identity, _source_path, pipelines, output} ->
        [
          schema_version: 2,
          source_identity: source_identity,
          pipelines: pipelines,
          output:
            if(output == :automatic,
              do: [
                mode: :automatic,
                modern_candidates: [:avif, :webp],
                auto: [avif: true, webp: true],
                quality: :default,
                format_qualities: %{}
              ],
              else: [
                mode: :explicit,
                format: output,
                quality: :default,
                format_qualities: %{}
              ]
            ),
          cache: [cachebuster: nil],
          selected_headers: [],
          selected_cookies: []
        ]
      end
    )
  end

  defp cacheable_plan(overrides \\ []) do
    map({source_path(), pipeline_structs()}, fn {source_path, pipelines} ->
      plan(
        Keyword.merge(
          [
            source: %Source.Path{segments: source_path},
            pipelines: pipelines
          ],
          overrides
        )
      )
    end)
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "cat.jpg"]},
          pipelines: [
            %Pipeline{
              operations: [resize_operation(300, :auto)]
            }
          ],
          output: %Output{mode: {:explicit, :webp}}
        ],
        overrides
      )
    )
  end

  defp pipeline_structs do
    list_of(map(list_of(operation(), min_length: 0, max_length: 3), &%Pipeline{operations: &1}),
      min_length: 1,
      max_length: 3
    )
  end

  defp pipelines do
    list_of(list_of(operation_data(), min_length: 0, max_length: 3),
      min_length: 1,
      max_length: 3
    )
  end

  defp operation do
    one_of([
      map({positive_pixel(), maybe_dimension_atom()}, fn {width, height} ->
        resize_operation(width, height)
      end),
      map({positive_pixel(), positive_pixel()}, fn {width, height} ->
        crop_guided_operation(width, height)
      end)
    ])
  end

  defp operation_data do
    one_of([
      map({positive_pixel(), maybe_dimension_atom()}, fn {width, height} ->
        [
          op: :resize,
          mode: :fit,
          width: [unit: :logical_px, value: width],
          height: dimension_data(height),
          dpr: [unit: :ratio, numerator: 1, denominator: 1],
          enlargement: :deny,
          guide: :center,
          x_offset: {:pixels, 0.0},
          y_offset: {:pixels, 0.0},
          min_width: nil,
          min_height: nil,
          zoom_x: 1.0,
          zoom_y: 1.0
        ]
      end),
      map({positive_pixel(), positive_pixel()}, fn {width, height} ->
        [
          op: :crop_guided,
          width: [unit: :logical_px, value: width],
          height: [unit: :logical_px, value: height],
          guide: :center,
          x_offset: {:pixels, 0.0},
          y_offset: {:pixels, 0.0}
        ]
      end)
    ])
  end

  defp resize_operation(width, height) do
    {:ok, operation} =
      Operation.resize(:fit, {:px, width}, tagged_resize_dimension(height), enlargement: :deny)

    operation
  end

  defp crop_guided_operation(width, height) do
    {:ok, operation} = Operation.crop_guided({:px, width}, {:px, height}, :center)
    operation
  end

  defp dimension_data(:auto), do: [unit: :auto]
  defp dimension_data(pixels), do: [unit: :logical_px, value: pixels]

  defp tagged_resize_dimension(:auto), do: :auto
  defp tagged_resize_dimension(pixels), do: {:px, pixels}

  defp source_identity do
    map(source_path(), fn path -> [kind: :path, root: "default", path: path] end)
  end

  defp source_path, do: list_of(path_segment(), min_length: 1, max_length: 4)
  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)
  defp maybe_dimension, do: one_of([constant(nil), constant(:auto), pixel_dimension()])
  defp maybe_dimension_atom, do: one_of([constant(:auto), positive_pixel()])
  defp pixel_dimension, do: map(integer(1..10_000), &{:pixels, &1})
  defp positive_pixel, do: integer(1..10_000)

  defp accept_header do
    map(list_of(media_range_with_optional_quality(), max_length: 5), &Enum.join(&1, ","))
  end

  defp media_range_with_optional_quality do
    one_of([
      media_range(),
      map({media_range(), integer(0..10)}, fn {range, q} -> "#{range}; q=#{q / 10}" end)
    ])
  end

  defp media_range do
    member_of(["image/avif", "image/webp", "image/jpeg", "image/png", "image/*", "*/*"])
  end
end
