defmodule ImagePipe.Dialect.TwicPics.IdentityTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.Identity
  alias ImagePipe.Dialect.TwicPics.Negotiation
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output.QualitySearch.Butteraugli
  alias ImagePipe.Plan.Output.QualitySearch.Ssimulacra2
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Representation

  defp request!(chain) do
    {:ok, request} = RequestBuilder.build(%Path{segments: ["images", "cat.jpg"]}, chain, config())
    request
  end

  defp config(overrides \\ []), do: Config.validate!(overrides)

  defp base_policy do
    %Policy{
      mode: :source,
      modern_candidates: [],
      headers: [{"vary", "Accept"}],
      quality: :default,
      format_qualities: %{},
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp negotiation(overrides \\ []) do
    policy = base_policy()

    base = [
      selected: {:image, :source_negotiated},
      vary?: true,
      policy_material: Policy.identity_material(policy),
      policy: policy
    ]

    struct!(Negotiation, Keyword.merge(base, overrides))
  end

  defp material(
         request,
         negotiation,
         conn \\ conn(:get, "/"),
         config \\ config(),
         detector \\ nil
       ) do
    Identity.material(request, negotiation, conn, config, detector)
  end

  defp representation(material) do
    source_identity = [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]
    Representation.build(source_identity, material, {:strong, source_identity})
  end

  describe "ordered canonical request" do
    test "reordering positional steps changes the representation, key, and ETag" do
      first = request!([{"cover", "120x80"}, {"contain", "60x40"}])
      reordered = request!([{"contain", "60x40"}, {"cover", "120x80"}])
      negotiation = negotiation()

      first_material = material(first, negotiation)
      reordered_material = material(reordered, negotiation)

      refute first_material.representation == reordered_material.representation

      refute representation(first_material).cache_key.hash ==
               representation(reordered_material).cache_key.hash

      refute representation(first_material).etag == representation(reordered_material).etag
    end

    test "normalized equivalent ratios and arithmetic produce the same identity" do
      ratio_a = request!([{"cover", "1.5:2"}, {"resize", "(700/2)"}])
      ratio_b = request!([{"cover", "3:4"}, {"resize", "350"}])
      negotiation = negotiation()

      material_a = material(ratio_a, negotiation)
      material_b = material(ratio_b, negotiation)

      assert material_a == material_b

      assert representation(material_a).cache_key.hash ==
               representation(material_b).cache_key.hash

      assert representation(material_a).etag == representation(material_b).etag
    end

    test "recursive canonicalization retains struct module discriminators" do
      fields = [target: 20, min_quality: 70, max_quality: 80, allowed_error: 0.5]
      request = request!([{"resize", "100"}])

      ssimulacra2 = %Request{
        request
        | output: %{request.output | quality_search: struct!(Ssimulacra2, fields)}
      }

      butteraugli = %Request{
        request
        | output: %{request.output | quality_search: struct!(Butteraugli, fields)}
      }

      first = material(ssimulacra2, negotiation())
      second = material(butteraugli, negotiation())

      refute first.representation == second.representation
      refute representation(first).etag == representation(second).etag
    end

    test "auto-rotate enters identity while response debug metadata does not" do
      request = request!([{"resize", "100"}])
      auto_rotate_off = %Request{request | auto_rotate: false}
      debug = %Request{request | response: %{request.response | debug?: true}}

      refute material(request, negotiation()).representation ==
               material(auto_rotate_off, negotiation()).representation

      assert material(request, negotiation()) == material(debug, negotiation())
    end
  end

  describe "negotiation and output intent" do
    test "selection and effective policy material both enter key and ETag" do
      request = request!([{"resize", "100"}])
      jpeg = negotiation(selected: {:image, :jpeg}, vary?: false)
      avif = negotiation(selected: {:image, :avif}, vary?: false)
      quality = negotiation(policy_material: [quality: {:quality, 42}])

      materials = Enum.map([jpeg, avif, quality], &material(request, &1))
      representations = Enum.map(materials, &representation/1)

      assert 3 == representations |> Enum.map(& &1.cache_key.hash) |> Enum.uniq() |> length()
      assert 3 == representations |> Enum.map(& &1.etag) |> Enum.uniq() |> length()
    end

    test "canonical output intent enters representation independently of policy material" do
      automatic = request!([{"resize", "100"}])
      explicit = request!([{"resize", "100"}, {"output", "jpeg"}])

      refute material(automatic, negotiation()).representation ==
               material(explicit, negotiation()).representation
    end
  end

  describe "positional face-assist identity" do
    test "detector identity enters only when auto focus reaches a focused consumer" do
      active = request!([{"focus", "auto"}, {"cover", "100x100"}])
      detector_a = material(active, negotiation(), conn(:get, "/"), config(), {:face, :v1})
      detector_b = material(active, negotiation(), conn(:get, "/"), config(), {:face, :v2})

      assert Keyword.fetch!(detector_a.representation, :detector) == {:face, :v1}

      refute representation(detector_a).cache_key.hash ==
               representation(detector_b).cache_key.hash

      refute representation(detector_a).etag == representation(detector_b).etag
    end

    test "a literal focus before the consumer deactivates face assist" do
      request =
        request!([
          {"focus", "auto"},
          {"focus", "20x30"},
          {"cover", "100x100"}
        ])

      with_detector = material(request, negotiation(), conn(:get, "/"), config(), {:face, :v1})
      without_detector = material(request, negotiation(), conn(:get, "/"), config(), nil)

      refute Keyword.has_key?(with_detector.representation, :detector)
      assert with_detector == without_detector
    end

    test "a region crop resets auto focus before a later focused consumer" do
      request =
        request!([
          {"focus", "auto"},
          {"crop", "20x20@0x0"},
          {"cover", "100x100"}
        ])

      with_detector = material(request, negotiation(), conn(:get, "/"), config(), {:face, :v1})
      without_detector = material(request, negotiation(), conn(:get, "/"), config(), nil)

      assert with_detector == without_detector
    end

    test "a detector supplied for an unrelated request is absent, not nil" do
      request = request!([{"resize", "100"}])
      result = material(request, negotiation(), conn(:get, "/"), config(), {:face, :v1})

      refute Keyword.has_key?(result.representation, :detector)
    end
  end

  describe "storage inputs and Vary" do
    test "header and cookie values change storage key but not ETag; only header names enter Vary" do
      request = request!([{"resize", "100"}])

      config =
        config(storage_inputs: [{:header, "X-Tenant"}, {:cookie, "session"}])

      first =
        :get
        |> conn("/")
        |> Plug.Conn.put_req_header("x-tenant", "a")
        |> Plug.Conn.put_req_header("cookie", "session=one")

      second =
        :get
        |> conn("/")
        |> Plug.Conn.put_req_header("x-tenant", "b")
        |> Plug.Conn.put_req_header("cookie", "session=two")

      first_material = material(request, negotiation(), first, config)
      second_material = material(request, negotiation(), second, config)
      first_representation = representation(first_material)
      second_representation = representation(second_material)

      assert first_material.storage_only ==
               ImagePipe.Representation.storage_inputs(first, config[:storage_inputs]) |> elem(0)

      assert first_representation.cache_key.hash != second_representation.cache_key.hash
      assert first_representation.etag == second_representation.etag
      assert Enum.sort(first_material.vary_header_names) == ["Accept", "x-tenant"]
      refute "session" in first_material.vary_header_names
    end

    test "explicit output omits Accept but preserves configured storage header Vary" do
      request = request!([{"output", "jpeg"}])
      config = config(storage_inputs: [{:header, "Save-Data"}, {:cookie, "session"}])

      result =
        material(
          request,
          negotiation(selected: {:image, :jpeg}, vary?: false),
          conn(:get, "/"),
          config
        )

      assert result.vary_header_names == ["save-data"]
    end
  end
end
