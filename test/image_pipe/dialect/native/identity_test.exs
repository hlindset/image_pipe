defmodule ImagePipe.Dialect.Native.IdentityTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Native.Identity
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Representation

  # `Parser.parse/2` consumes Task 4's lexed map directly, mirroring
  # `parser_test.exs`/`canonical_property_test.exs` — this exercises the
  # real canonicalizing parser rather than hand-built `%Request{}` structs.
  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp request!(segments) do
    {:ok, request} = Parser.parse(lexed(segments), [])
    request
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
      policy_material: Policy.identity_material(base_policy()),
      policy: nil,
      plan_output: nil
    ]

    struct!(Negotiation, Keyword.merge(base, overrides))
  end

  defp material(request, negotiation, conn \\ conn(:get, "/"), config \\ []) do
    Identity.material(request, negotiation, conn, config)
  end

  defp source_identity,
    do: [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]

  # Identity tests assert ETag material, so they use a strong byte identity
  # (the `:none` withholding contract lives in the representation + wire tests).
  defp build(source_identity, material),
    do: Representation.build(source_identity, material, {:strong, source_identity})

  describe "canonical request composition" do
    test "two spellings of the same group produce identical material" do
      a = request!(["w=300", "h=400", "fit=cover", "anchor=smart"])
      b = request!(["fit=cover", "w=300", "anchor=smart", "h=400"])

      neg = negotiation()

      assert material(a, neg) == material(b, neg)
    end
  end

  describe "negotiation outcome composition" do
    test "different Accept headers selecting the same format yield identical material" do
      request = request!(["w=300"])
      neg = negotiation(selected: {:image, :avif})

      conn_a = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif")
      conn_b = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif,image/webp")

      assert material(request, neg, conn_a) == material(request, neg, conn_b)
    end

    test "different selected formats yield different representation" do
      request = request!(["w=300"])

      avif = material(request, negotiation(selected: {:image, :avif}))
      webp = material(request, negotiation(selected: {:image, :webp}))

      assert avif.representation != webp.representation
    end

    test "two no-modern-candidate headers yield identical material via the source_negotiated sentinel" do
      request = request!(["w=300"])
      neg = negotiation(selected: {:image, :source_negotiated})

      conn_a = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/jpeg")
      conn_b = conn(:get, "/")

      assert material(request, neg, conn_a) == material(request, neg, conn_b)
    end
  end

  describe "vary_header_names" do
    test "automatic negotiation puts Accept in vary_header_names" do
      request = request!(["w=300"])
      mat = material(request, negotiation(vary?: true))

      assert "Accept" in mat.vary_header_names
    end

    test "explicit format puts nothing in vary_header_names" do
      request = request!(["w=300", "format=avif"])
      neg = negotiation(selected: {:image, :avif}, vary?: false)

      mat = material(request, neg)

      assert mat.vary_header_names == []
    end

    test "the blurhash terminal puts nothing in vary_header_names" do
      request = request!(["w=32", "output=blurhash"])
      neg = negotiation(selected: {:terminal, :blurhash}, vary?: false, policy_material: [])

      mat = material(request, neg)

      assert mat.vary_header_names == []
    end
  end

  describe "explicit format" do
    test "selection is {:image, format} regardless of Accept" do
      request = request!(["w=300", "format=avif"])
      neg = negotiation(selected: {:image, :avif}, vary?: false)

      conn_a = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/webp")
      conn_b = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif")

      mat_a = material(request, neg, conn_a)
      mat_b = material(request, neg, conn_b)

      assert Keyword.fetch!(mat_a.representation, :selection) == {:image, :avif}
      assert mat_a.representation == mat_b.representation
    end
  end

  describe "blurhash terminal" do
    test "the terminal computation's identity enters representation, not a selection outcome" do
      request = request!(["w=32", "output=blurhash"])
      neg = negotiation(selected: {:terminal, :blurhash}, vary?: false, policy_material: [])

      mat = material(request, neg)

      assert Keyword.fetch!(mat.representation, :terminal) == Blurhash.identity()
      refute Keyword.has_key?(mat.representation, :selection)
    end

    test "an :image-vs-:blurhash request differs" do
      image_request = request!(["w=32"])
      blurhash_request = request!(["w=32", "output=blurhash"])

      image_mat = material(image_request, negotiation(selected: {:image, :source_negotiated}))

      blurhash_mat =
        material(
          blurhash_request,
          negotiation(selected: {:terminal, :blurhash}, vary?: false, policy_material: [])
        )

      assert image_mat.representation != blurhash_mat.representation
    end
  end

  describe "output-policy material" do
    test "two requests differing only in q differ in representation" do
      conn0 = conn(:get, "/")
      request_a = request!(["w=300", "q=50"])
      request_b = request!(["w=300", "q=90"])

      policy_a = Policy.from_output_plan(conn0, Identity.plan_output(request_a), [])
      policy_b = Policy.from_output_plan(conn0, Identity.plan_output(request_b), [])

      mat_a =
        material(request_a, negotiation(policy_material: Policy.identity_material(policy_a)))

      mat_b =
        material(request_b, negotiation(policy_material: Policy.identity_material(policy_b)))

      assert mat_a.representation != mat_b.representation
    end

    test "material carries the effective-default policy fields even with no output option spelled" do
      conn0 = conn(:get, "/")
      request = request!(["w=300"])

      policy = Policy.from_output_plan(conn0, Identity.plan_output(request), [])
      mat = material(request, negotiation(policy_material: Policy.identity_material(policy)))

      output_policy_material = Keyword.fetch!(mat.representation, :output_policy)

      assert Keyword.fetch!(output_policy_material, :quality) == :default
      assert Keyword.fetch!(output_policy_material, :default_quality) == :default
      assert Keyword.fetch!(output_policy_material, :strip_metadata) == true
      assert Keyword.fetch!(output_policy_material, :keep_copyright) == true
      assert Keyword.fetch!(output_policy_material, :color_profile) == :strip
    end

    test "two hand-built %Policy{} differing only in default_quality yield different representation and ETags" do
      policy_a = %{base_policy() | default_quality: {:quality, 70}}
      policy_b = %{base_policy() | default_quality: {:quality, 90}}

      request = request!(["w=300"])

      mat_a =
        material(request, negotiation(policy_material: Policy.identity_material(policy_a)))

      mat_b =
        material(request, negotiation(policy_material: Policy.identity_material(policy_b)))

      assert mat_a.representation != mat_b.representation

      rep_a = build(source_identity(), mat_a)
      rep_b = build(source_identity(), mat_b)

      assert rep_a.etag != rep_b.etag
    end
  end

  describe "expires and signature never enter identity" do
    test "requests differing only in expires produce identical material" do
      request_a = request!(["w=300"])
      request_b = request!(["w=300", "expires=1999999999"])

      refute request_a.expires == request_b.expires

      neg = negotiation()

      assert material(request_a, neg) == material(request_b, neg)
    end

    test "expires never appears anywhere in representation or storage_only" do
      request = request!(["w=300", "expires=1999999999"])
      mat = material(request, negotiation())

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

  describe "storage_inputs integration (Task 9)" do
    test "a configured storage_inputs header moves the key but not the ETag, and names Vary" do
      request = request!(["w=300"])
      config = [storage_inputs: [{:header, "Save-Data"}]]

      conn_a = :get |> conn("/") |> Plug.Conn.put_req_header("save-data", "on")
      conn_b = :get |> conn("/") |> Plug.Conn.put_req_header("save-data", "off")

      neg = negotiation()

      mat_a = material(request, neg, conn_a, config)
      mat_b = material(request, neg, conn_b, config)

      assert "save-data" in mat_a.vary_header_names

      rep_a = build(source_identity(), mat_a)
      rep_b = build(source_identity(), mat_b)

      assert rep_a.cache_key.hash != rep_b.cache_key.hash
      assert rep_a.etag == rep_b.etag
    end
  end
end
