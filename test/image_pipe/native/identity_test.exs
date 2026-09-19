defmodule ImagePipe.Native.IdentityTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Native
  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Identity
  alias ImagePipe.Native.Output
  alias ImagePipe.Native.Parser
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Representation

  defmodule ClassIdentityDetector do
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_opts), do: ["car", "face"]

    @impl true
    def available?(_opts), do: true

    @impl true
    def identity(opts), do: {__MODULE__, Keyword.fetch!(opts, :classes)}

    @impl true
    def detect(_image, _opts), do: {:ok, []}
  end

  # `Parser.parse/2` consumes Task 4's lexed map directly, mirroring
  # `parser_test.exs`/`canonical_property_test.exs` — this exercises the
  # real canonicalizing parser rather than hand-built `%Request{}` structs.
  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp request!(segments) do
    {:ok, request} = Parser.parse(lexed(segments), Config.validate!([]))
    request
  end

  defp output_policy!(request, config \\ [], accept \\ "") do
    {:ok, output} = Output.resolve(request.output, Config.validate!(config), accept)
    output
  end

  defp policy(format \\ :automatic, accept \\ nil) do
    segments = if format == :automatic, do: [], else: ["format=#{format}"]
    output_policy!(request!(segments), [auto_avif: true, auto_webp: true], accept || "")
  end

  defp material(
         request,
         negotiation,
         conn \\ conn(:get, "/"),
         config \\ [],
         detector_identity \\ nil
       ) do
    Identity.material(request, negotiation, conn, config, detector_identity)
  end

  defp source_identity,
    do: [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]

  # Identity tests assert ETag material, so they use a strong byte identity
  # (the `:none` withholding contract lives in the representation + wire tests).
  defp build(source_identity, material),
    do: Representation.build(source_identity, material, {:strong, source_identity})

  defp prepared_material!(segments, config_opts \\ []) do
    request = request!(segments)

    config =
      [detector: ClassIdentityDetector]
      |> Keyword.merge(config_opts)
      |> Config.validate!()

    assert {:ok, _source, policy} = Native.prepare(request, config, "")
    conn = conn(:get, "/")

    Native.identity_material(request, policy, conn, config)
  end

  describe "canonical request composition" do
    test "two spellings of the same group produce identical material" do
      a = request!(["w=300", "h=400", "fit=cover", "anchor=smart"])
      b = request!(["fit=cover", "w=300", "anchor=smart", "h=400"])

      neg = policy()

      assert material(a, neg) == material(b, neg)
    end

    test "explicit auto orientation is the default and none changes representation identity" do
      default_request = request!(["w=300"])
      auto_request = request!(["orient=auto", "w=300"])
      none_request = request!(["orient=none", "w=300"])
      neg = policy()

      assert material(default_request, neg) == material(auto_request, neg)

      refute material(default_request, neg).representation ==
               material(none_request, neg).representation
    end

    test "geometry scale defaults canonicalize while effective values change identity" do
      default_request = request!(["w=300"])
      explicit_defaults = request!(["w=300", "dpr=1", "zoom=1"])
      scaled_request = request!(["w=300", "dpr=2", "zoom=1.5,0.75"])
      minimum_request = request!(["min-w=300"])
      neg = policy()

      assert material(default_request, neg) == material(explicit_defaults, neg)
      refute material(default_request, neg) == material(scaled_request, neg)
      refute material(default_request, neg) == material(minimum_request, neg)
    end
  end

  describe "detector identity" do
    test "a relevant detector model identity changes representation and ETag" do
      request = request!(["w=300"])
      neg = policy()

      mat_v1 = material(request, neg, conn(:get, "/"), [], {:detector, :v1})
      mat_v2 = material(request, neg, conn(:get, "/"), [], {:detector, :v2})

      assert Keyword.fetch!(mat_v1.representation, :detector) == {:detector, :v1}
      assert mat_v1.representation != mat_v2.representation
      assert build(source_identity(), mat_v1).etag != build(source_identity(), mat_v2).etag
    end

    test "nil detector identity does not add representation material" do
      request = request!(["w=300"])

      mat = material(request, policy())

      refute Keyword.has_key?(mat.representation, :detector)
    end

    test "request preparation resolves identity for the union of explicit and face-assisted classes" do
      material =
        prepared_material!([
          "crop=100,100",
          "detect=car",
          "then",
          "crop=50,50",
          "anchor=smart-face"
        ])

      assert Keyword.fetch!(material.representation, :detector) ==
               {ClassIdentityDetector, ["car", "face"]}
    end

    test "all-class detection dominates face assistance for detector identity" do
      material =
        prepared_material!([
          "crop=100,100",
          "detect=all",
          "then",
          "crop=50,50",
          "anchor=smart-face"
        ])

      assert Keyword.fetch!(material.representation, :detector) ==
               {ClassIdentityDetector, :all}
    end

    test "requests without detection omit detector identity" do
      material = prepared_material!(["crop=100,100", "anchor=smart"])

      refute Keyword.has_key?(material.representation, :detector)
    end
  end

  describe "negotiation outcome composition" do
    test "different Accept headers selecting the same format yield identical material" do
      request = request!(["w=300"])
      neg = policy(:automatic, "image/avif")

      conn_a = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif")
      conn_b = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif,image/webp")

      assert material(request, neg, conn_a) == material(request, neg, conn_b)
    end

    test "different selected formats yield different representation" do
      request = request!(["w=300"])

      avif = material(request, policy(:automatic, "image/avif"))
      webp = material(request, policy(:automatic, "image/webp"))

      assert avif.representation != webp.representation
    end

    test "two no-modern-candidate headers yield identical material via the source_negotiated sentinel" do
      request = request!(["w=300"])
      neg = policy()

      conn_a = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/jpeg")
      conn_b = conn(:get, "/")

      assert material(request, neg, conn_a) == material(request, neg, conn_b)
    end
  end

  describe "vary_header_names" do
    test "automatic negotiation puts Accept in vary_header_names" do
      request = request!(["w=300"])
      mat = material(request, policy())

      assert "Accept" in mat.vary_header_names
    end

    test "explicit format puts nothing in vary_header_names" do
      request = request!(["w=300", "format=avif"])
      neg = policy(:avif)

      mat = material(request, neg)

      assert mat.vary_header_names == []
    end

    test "the blurhash terminal puts nothing in vary_header_names" do
      request = request!(["w=32", "output=blurhash"])
      neg = nil

      mat = material(request, neg)

      assert mat.vary_header_names == []
    end
  end

  describe "explicit format" do
    test "selection is {:image, format} regardless of Accept" do
      request = request!(["w=300", "format=avif"])
      neg = policy(:avif)

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
      neg = nil

      mat = material(request, neg)

      assert Keyword.fetch!(mat.representation, :terminal) == Blurhash.identity()
      refute Keyword.has_key?(mat.representation, :selection)
    end

    test "an :image-vs-:blurhash request differs" do
      image_request = request!(["w=32"])
      blurhash_request = request!(["w=32", "output=blurhash"])

      image_mat = material(image_request, policy())

      blurhash_mat =
        material(
          blurhash_request,
          nil
        )

      assert image_mat.representation != blurhash_mat.representation
    end
  end

  describe "info terminal" do
    test "uses only the versioned info computation as representation material" do
      request = request!(["output=info"])
      negotiation = nil

      mat = material(request, negotiation)

      assert mat.representation == [terminal: {:info, 1}]
      assert mat.vary_header_names == []
    end

    test "filename and attachment stay outside representation and storage identity" do
      plain = request!(["output=info"])
      presented = request!(["output=info", "filename=report", "attachment"])
      negotiation = nil

      assert material(plain, negotiation) == material(presented, negotiation)
    end
  end

  describe "output-policy material" do
    test "equal effective metadata, profile, and HDR policy has equal concrete identity" do
      host_material =
        prepared_material!([],
          strip_metadata: false,
          keep_copyright: false,
          strip_color_profile: false,
          preserve_hdr: true
        )

      url_material = prepared_material!(["meta=keep", "profile=preserve", "hdr=preserve"])

      assert host_material.representation == url_material.representation

      output_policy = Keyword.fetch!(host_material.representation, :output_policy)
      assert Keyword.fetch!(output_policy, :strip_metadata) == false
      assert Keyword.fetch!(output_policy, :keep_copyright) == false
      assert Keyword.fetch!(output_policy, :color_profile) == :preserve_source
      assert Keyword.fetch!(output_policy, :hdr) == :preserve
    end

    test "two requests differing only in q differ in representation" do
      request_a = request!(["w=300", "q=50"])
      request_b = request!(["w=300", "q=90"])

      policy_a = output_policy!(request_a)
      policy_b = output_policy!(request_b)

      mat_a =
        material(request_a, policy_a)

      mat_b =
        material(request_b, policy_b)

      assert mat_a.representation != mat_b.representation
    end

    test "material carries the effective-default policy fields even with no output option spelled" do
      request = request!(["w=300"])

      policy = output_policy!(request)
      mat = material(request, policy)

      output_policy_material = Keyword.fetch!(mat.representation, :output_policy)

      assert Keyword.fetch!(output_policy_material, :quality) == :default
      assert Keyword.fetch!(output_policy_material, :default_quality) == {:quality, 80}
      assert Keyword.fetch!(output_policy_material, :strip_metadata) == true
      assert Keyword.fetch!(output_policy_material, :keep_copyright) == true
      assert Keyword.fetch!(output_policy_material, :color_profile) == :strip
    end

    test "different configured default quality yields different representation and ETags" do
      request = request!(["w=300"])
      policy_a = output_policy!(request, quality: 70)
      policy_b = output_policy!(request, quality: 90)

      mat_a =
        material(request, policy_a)

      mat_b =
        material(request, policy_b)

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

      neg = policy()

      assert material(request_a, neg) == material(request_b, neg)
    end

    test "expires never appears anywhere in representation or storage_only" do
      request = request!(["w=300", "expires=1999999999"])
      mat = material(request, policy())

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

      neg = policy()

      mat_a = material(request, neg, conn_a, config)
      mat_b = material(request, neg, conn_b, config)

      assert "save-data" in mat_a.vary_header_names

      rep_a = build(source_identity(), mat_a)
      rep_b = build(source_identity(), mat_b)

      assert rep_a.cache_key.hash != rep_b.cache_key.hash
      assert rep_a.etag == rep_b.etag
    end
  end

  describe "cachebuster" do
    test "changes storage identity and the cache key without changing the ETag" do
      negotiation = nil
      plain = material(request!(["output=info"]), negotiation)
      busted = material(request!(["output=info", "cb=v2"]), negotiation)

      refute Keyword.has_key?(plain.storage_only, :cachebuster)
      assert Keyword.fetch!(busted.storage_only, :cachebuster) == "v2"

      plain_representation = build(source_identity(), plain)
      busted_representation = build(source_identity(), busted)

      refute plain_representation.cache_key.hash == busted_representation.cache_key.hash
      assert plain_representation.etag == busted_representation.etag
    end
  end
end
