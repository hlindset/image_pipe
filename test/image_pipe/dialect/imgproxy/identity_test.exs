defmodule ImagePipe.Dialect.Imgproxy.IdentityTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy.CropRequest
  alias ImagePipe.Dialect.Imgproxy.Effects
  alias ImagePipe.Dialect.Imgproxy.Identity
  alias ImagePipe.Dialect.Imgproxy.Negotiation
  alias ImagePipe.Dialect.Imgproxy.Orientation
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output.JpegOptions
  alias ImagePipe.Plan.Output.QualitySearch.Size, as: SizeSearch
  alias ImagePipe.Representation

  defp request(overrides \\ []) do
    base = [
      signature: "unsafe",
      source_kind: :plain,
      source_path: "images/x.jpg",
      pipelines: [%PipelineRequest{width: 300}]
    ]

    struct!(Request, Keyword.merge(base, overrides))
  end

  defp base_policy do
    %Policy{
      mode: :source,
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{},
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp negotiation(overrides \\ []) do
    base = [
      selected: {:image, :source_negotiated},
      vary?: true,
      policy_material: Policy.identity_material(base_policy())
    ]

    struct!(Negotiation, Keyword.merge(base, overrides))
  end

  defp material(request, negotiation, conn \\ conn(:get, "/"), config \\ []) do
    Identity.material(request, negotiation, conn, config)
  end

  defp source_identity,
    do: [kind: :path, adapter: :path, root: "default", path: ["images", "x.jpg"]]

  describe "response fields are excluded from identity" do
    test "two requests differing only in response.filename produce identical material" do
      a = request(response: Request.response_request(filename: "a.jpg"))
      b = request(response: Request.response_request(filename: "b.jpg"))

      neg = negotiation()

      assert material(a, neg) == material(b, neg)
    end

    test "two requests differing only in response.debug? produce identical material" do
      a = request(response: Request.response_request(debug?: true))
      b = request(response: Request.response_request(debug?: false))

      neg = negotiation()

      assert material(a, neg) == material(b, neg)
    end

    test "response.disposition never enters identity either" do
      a = request(response: Request.response_request(disposition: :inline))
      b = request(response: Request.response_request(disposition: :attachment))

      neg = negotiation()

      assert material(a, neg) == material(b, neg)
    end
  end

  describe "cachebuster" do
    test "differing cache.cachebuster yields equal representation but differing storage_only" do
      a = request(cache: Request.cache_request(cachebuster: "v1"))
      b = request(cache: Request.cache_request(cachebuster: "v2"))

      neg = negotiation()

      mat_a = material(a, neg)
      mat_b = material(b, neg)

      assert mat_a.representation == mat_b.representation
      refute mat_a.storage_only == mat_b.storage_only
    end

    test "cachebuster busts the cache key but not the ETag" do
      a = request(cache: Request.cache_request(cachebuster: "v1"))
      b = request(cache: Request.cache_request(cachebuster: "v2"))

      neg = negotiation()

      rep_a = Representation.build(source_identity(), material(a, neg))
      rep_b = Representation.build(source_identity(), material(b, neg))

      assert rep_a.cache_key.hash != rep_b.cache_key.hash
      assert rep_a.etag == rep_b.etag
    end
  end

  describe "signature and expires never enter identity" do
    test "differing signature produces identical material" do
      a = request(signature: "unsafe")
      b = request(signature: "sig-abc")

      neg = negotiation()

      assert material(a, neg) == material(b, neg)
    end

    test "differing policy.expires produces identical material" do
      a = request(policy: Request.policy_request(expires: 0))
      b = request(policy: Request.policy_request(expires: 1_999_999_999))

      neg = negotiation()

      assert material(a, neg) == material(b, neg)
    end

    test "expires never appears anywhere in representation or storage_only" do
      req = request(policy: Request.policy_request(expires: 1_999_999_999))
      mat = material(req, negotiation())

      refute contains_value?(mat.representation, 1_999_999_999)
      refute contains_value?(mat.storage_only, 1_999_999_999)
    end

    defp contains_value?(term, value) when term == value, do: true

    defp contains_value?(term, value) when is_tuple(term) do
      term |> Tuple.to_list() |> contains_value?(value)
    end

    defp contains_value?(term, value) when is_list(term) do
      Enum.any?(term, &contains_value?(&1, value))
    end

    defp contains_value?(term, value) when is_map(term) do
      term |> Map.to_list() |> contains_value?(value)
    end

    defp contains_value?(_term, _value), do: false
  end

  describe "auto_rotate" do
    test "differing auto_rotate produces differing representation" do
      a = request(auto_rotate: true)
      b = request(auto_rotate: false)

      neg = negotiation()

      refute material(a, neg).representation == material(b, neg).representation
    end
  end

  describe "vary_header_names" do
    test "vary? true puts Accept in vary_header_names" do
      mat = material(request(), negotiation(vary?: true))

      assert "Accept" in mat.vary_header_names
    end

    test "vary? false leaves Accept out of vary_header_names" do
      mat = material(request(), negotiation(vary?: false))

      refute "Accept" in mat.vary_header_names
    end
  end

  describe "the /info terminal" do
    test "selection is {:terminal, :info}, distinct from the image terminal" do
      neg = negotiation(selected: {:terminal, :info}, vary?: false, policy_material: [])
      mat = material(request(), neg)

      assert Keyword.fetch!(mat.representation, :terminal) == :info
      refute Keyword.has_key?(mat.representation, :selection)
    end

    test "an image-vs-info request differs" do
      image_mat = material(request(), negotiation(selected: {:image, :source_negotiated}))

      info_mat =
        material(
          request(),
          negotiation(selected: {:terminal, :info}, vary?: false, policy_material: [])
        )

      assert image_mat.representation != info_mat.representation
    end
  end

  describe "explicit format selection" do
    test "selection is {:image, format} and enters representation" do
      neg = negotiation(selected: {:image, :avif}, vary?: false)
      mat = material(request(), neg)

      assert Keyword.fetch!(mat.representation, :selection) == {:image, :avif}
    end
  end

  describe "plan_output/1" do
    test "no format spelled -> automatic mode" do
      req = request(output: Request.output_request())

      assert Identity.plan_output(req).mode == :automatic
    end

    test "an explicit format -> {:explicit, format} mode" do
      req = request(output: Request.output_request(format: :avif))

      assert Identity.plan_output(req).mode == {:explicit, :avif}
    end

    test "color_profile: cp target wins over strip_color_profile" do
      req =
        request(output: Request.output_request(color_profile: :srgb, strip_color_profile: false))

      assert Identity.plan_output(req).color_profile == {:convert, :srgb}
    end

    test "strip_color_profile alone resolves to :strip / :preserve_source" do
      stripped = request(output: Request.output_request(strip_color_profile: true))
      preserved = request(output: Request.output_request(strip_color_profile: false))

      assert Identity.plan_output(stripped).color_profile == :strip
      assert Identity.plan_output(preserved).color_profile == :preserve_source
    end

    test "preserve_hdr maps to :preserve / :tone_map" do
      preserved = request(output: Request.output_request(preserve_hdr: true))
      tone_mapped = request(output: Request.output_request(preserve_hdr: false))

      assert Identity.plan_output(preserved).hdr == :preserve
      assert Identity.plan_output(tone_mapped).hdr == :tone_map
    end
  end

  describe "nested-struct fields survive canonicalization (no MaterialDigest crash)" do
    test "effects/orientation/crop/background_color and a resolved quality_search + encoder_options digest cleanly" do
      {:ok, background_color} = Color.rgb(10, 20, 30)

      pipeline = %PipelineRequest{
        width: 300,
        effects: %Effects{blur: 1.5, brightness: 10},
        orientation: %Orientation{auto_orient: true, rotate: 90},
        crop: %CropRequest{width: 100, height: 100},
        background_color: background_color
      }

      output =
        Request.output_request(
          quality_search: %SizeSearch{target: 50_000, min_quality: 40, max_quality: 90},
          encoder_options: %{jpeg: %JpegOptions{}}
        )

      req = request(pipelines: [pipeline], output: output)
      mat = material(req, negotiation())

      representation = Representation.build(source_identity(), mat)

      assert is_binary(representation.etag)
      assert is_binary(representation.cache_key.hash)
    end
  end
end
