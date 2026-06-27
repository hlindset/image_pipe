defmodule ImagePipe.Output.PolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch

  describe "from_output_plan/3" do
    test "automatic output policy exposes Vary Accept and selected candidates from Accept" do
      conn =
        :get
        |> conn("/image")
        |> put_req_header("accept", "image/webp,image/avif;q=0.1")

      policy = Policy.from_output_plan(conn, %Output{mode: :automatic}, [])

      assert policy.headers == [{"vary", "Accept"}]
      assert policy.modern_candidates == [:avif, :webp]
    end

    test "represents explicit output independently of Accept" do
      conn =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept", "image/jpeg")

      assert Policy.from_output_plan(conn, %Output{mode: {:explicit, :webp}}, []) ==
               %Policy{
                 mode: {:explicit, :webp},
                 modern_candidates: [],
                 headers: [],
                 quality: :default,
                 format_qualities: %{},
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }
    end

    test "represents automatic output as source mode plus modern candidates" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

      assert Policy.from_output_plan(conn, %Output{mode: :automatic}, []) ==
               %Policy{
                 mode: :source,
                 modern_candidates: [:avif, :webp],
                 headers: [{"vary", "Accept"}],
                 quality: :default,
                 format_qualities: %{},
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }
    end

    test "keeps automatic Vary when Accept has no modern format signal" do
      cases = [
        conn(:get, "/_/plain/images/cat.jpg"),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", ""),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", "*/*"),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", "*/*;q=1"),
        conn(:get, "/_/plain/images/cat.jpg")
        |> put_req_header("accept", "application/json,*/*;q=1")
      ]

      for conn <- cases do
        assert %Policy{
                 mode: :source,
                 modern_candidates: [],
                 headers: [{"vary", "Accept"}],
                 quality: :default,
                 format_qualities: %{}
               } = Policy.from_output_plan(conn, %Output{mode: :automatic}, [])
      end
    end
  end

  describe "resolve/2" do
    test "selects explicit format before source fetch" do
      policy = %Policy{
        mode: {:explicit, :png},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve(policy, nil) ==
               {:ok,
                %Resolved{
                  format: :png,
                  quality: :default,
                  response_headers: [],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip
                }}
    end

    test "selects modern automatic format before source fetch" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [:avif, :webp],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve(policy, nil) ==
               {:ok,
                %Resolved{
                  format: :avif,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip
                }}
    end

    test "requires source format when automatic output has no modern candidate" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve(policy, nil) == {:error, :source_format_required}
    end

    test "uses source format without strict Accept rejection" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve(policy, :png) ==
               {:ok,
                %Resolved{
                  format: :png,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip
                }}

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :jpeg,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip
                }}
    end

    test "transcodes modern source formats to raster when no modern format is accepted" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve(policy, :webp) == {:needs_final_image_alpha, :source}
      assert Policy.resolve(policy, :avif) == {:needs_final_image_alpha, :source}
    end

    test "defers source-only fallback until final image alpha is known" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve(policy, :heif) == {:needs_final_image_alpha, :source}
      assert Policy.resolve(policy, :tiff) == {:needs_final_image_alpha, :source}

      assert Policy.resolve(policy, :jpeg2000) ==
               {:needs_final_image_alpha, :source}

      assert Policy.resolve(policy, :jpeg_xl) == {:needs_final_image_alpha, :source}
    end
  end

  describe "resolve_final_image_alpha/2" do
    test "selects png when final image has alpha" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve_final_image_alpha(policy, true) ==
               %Resolved{
                 format: :png,
                 quality: :default,
                 response_headers: [{"vary", "Accept"}],
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }
    end

    test "selects jpeg when final image has no alpha" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve_final_image_alpha(policy, false) ==
               %Resolved{
                 format: :jpeg,
                 quality: :default,
                 response_headers: [{"vary", "Accept"}],
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }
    end

    test "applies quality for selected alpha fallback format" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{jpeg: {:quality, 82}, png: {:quality, 70}},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.resolve_final_image_alpha(policy, false) ==
               %Resolved{
                 format: :jpeg,
                 quality: {:quality, 82},
                 response_headers: [{"vary", "Accept"}],
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }

      assert Policy.resolve_final_image_alpha(policy, true) ==
               %Resolved{
                 format: :png,
                 quality: {:quality, 70},
                 response_headers: [{"vary", "Accept"}],
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }
    end
  end

  describe "quality resolution" do
    test "explicit global quality wins over matching format quality regardless of URL order" do
      plan = %Output{
        mode: {:explicit, :webp},
        quality: {:quality, 80},
        format_qualities: %{webp: {:quality, 70}}
      }

      policy = Policy.from_output_plan(conn(:get, "/image"), plan, [])

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :webp,
                  quality: {:quality, 80},
                  response_headers: [],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip
                }}
    end

    test "format quality supplies default only when global quality is default" do
      plan = %Output{
        mode: {:explicit, :webp},
        quality: :default,
        format_qualities: %{webp: {:quality, 70}}
      }

      policy = Policy.from_output_plan(conn(:get, "/image"), plan, [])

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :webp,
                  quality: {:quality, 70},
                  response_headers: [],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip
                }}
    end
  end

  describe "quality search resolution" do
    defp policy_with(search, opts \\ []) do
      %Policy{
        mode: {:explicit, Keyword.get(opts, :format, :jpeg)},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip,
        quality_search: search,
        max_bytes: Keyword.get(opts, :max_bytes)
      }
    end

    test "per-format clamp overrides the global bracket for the negotiated format" do
      search = %QualitySearch.Ssimulacra2{
        target: 90.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0,
        format_min: %{avif: 60},
        format_max: %{avif: 65}
      }

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = rs}} =
               Policy.resolve(policy_with(search, format: :avif), nil)

      assert rs.min_quality == 60 and rs.max_quality == 65
    end

    test "unlisted format falls back to the global bracket" do
      search = %QualitySearch.Ssimulacra2{
        target: 90.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0,
        format_min: %{avif: 60},
        format_max: %{avif: 65}
      }

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = rs}} =
               Policy.resolve(policy_with(search, format: :jpeg), nil)

      assert rs.min_quality == 70 and rs.max_quality == 80
    end

    test "carries target, allowed_error, and max_resolution through" do
      search = %QualitySearch.Ssimulacra2{
        target: 90.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0,
        max_resolution: 16
      }

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = rs}} =
               Policy.resolve(policy_with(search), nil)

      assert rs.target == 90.0
      assert rs.allowed_error == 1.0
      assert rs.max_resolution == 16
    end

    test "resolves quality_search_offsets to the per-class map for an avif negotiation" do
      search = %QualitySearch.Ssimulacra2{
        target: 78.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0
      }

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = rs}} =
               Policy.resolve(policy_with(search, format: :avif), nil)

      # avif × graphic draws the big offset; photo keeps the lean default.
      assert rs.quality_search_offsets == %{photo: 2.4, graphic: 6.0}
    end

    test "a non-avif format keeps the lean default for both classes" do
      search = %QualitySearch.Ssimulacra2{
        target: 78.0,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0
      }

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = rs}} =
               Policy.resolve(policy_with(search, format: :jpeg), nil)

      assert rs.quality_search_offsets == %{photo: 2.4, graphic: 2.4}
    end

    test "butteraugli plan resolves to external Butteraugli resolved struct (non-JXL)" do
      search = %QualitySearch.Butteraugli{
        target: 1.0,
        min_quality: 1,
        max_quality: 100,
        allowed_error: 0.1
      }

      assert {:ok,
              %Resolved{quality_search: %ResolvedQualitySearch.Butteraugli{target: 1.0} = rs}} =
               Policy.resolve(policy_with(search, format: :webp), nil)

      assert rs.allowed_error == 0.1
    end

    test "butteraugli + JXL resolves to the native strategy" do
      search = %QualitySearch.Butteraugli{
        target: 1.0,
        min_quality: 1,
        max_quality: 100,
        allowed_error: 0.1
      }

      assert {:ok,
              %Resolved{
                quality_search: %ResolvedQualitySearch.NativeJxlButteraugli{target: 1.0}
              }} =
               Policy.resolve(policy_with(search, format: :jpeg_xl), nil)
    end

    test "butteraugli + webp stays external" do
      search = %QualitySearch.Butteraugli{
        target: 1.0,
        min_quality: 1,
        max_quality: 100,
        allowed_error: 0.1
      }

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Butteraugli{}}} =
               Policy.resolve(policy_with(search, format: :webp), nil)
    end

    test "none stays none" do
      assert {:ok, %Resolved{quality_search: :none}} = Policy.resolve(policy_with(:none), nil)
    end

    test "max_bytes is carried through to Resolved" do
      assert {:ok, %Resolved{max_bytes: 51_200}} =
               Policy.resolve(policy_with(:none, max_bytes: 51_200), nil)
    end
  end

  describe "supports_hdr?/3" do
    test "true only when policy is :preserve and the resolved format carries HDR" do
      conn = conn(:get, "/")

      png = Policy.from_output_plan(conn, %Output{mode: {:explicit, :png}}, [])
      jpeg = Policy.from_output_plan(conn, %Output{mode: {:explicit, :jpeg}}, [])

      preserve = %Output{mode: {:explicit, :png}, hdr: :preserve}
      tone_map = %Output{mode: {:explicit, :png}, hdr: :tone_map}

      # PNG carries HDR
      assert Policy.supports_hdr?(png, preserve, :png)
      # tone_map policy never preserves
      refute Policy.supports_hdr?(png, tone_map, :png)
      # JPEG cannot carry HDR even when preserve is requested
      refute Policy.supports_hdr?(jpeg, %{preserve | mode: {:explicit, :jpeg}}, :jpeg)
    end

    test "false when the format is only resolvable from the post-transform image (conservative tone-map)" do
      # automatic mode + no modern Accept + modern source → :needs_final_image_alpha → false
      conn = conn(:get, "/")
      policy = Policy.from_output_plan(conn, %Output{mode: :automatic}, [])
      preserve = %Output{mode: :automatic, hdr: :preserve}

      refute Policy.supports_hdr?(policy, preserve, :avif)
    end
  end

  describe "ensure_capable/2" do
    test "rejects an explicit format the build cannot write" do
      policy = %Policy{
        mode: {:explicit, :avif},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.ensure_capable(policy, output_capabilities: %{avif: false}) ==
               {:error, {:unsupported_output_format, :avif}}
    end

    test "allows a supported explicit format" do
      policy = %Policy{
        mode: {:explicit, :avif},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.ensure_capable(policy, output_capabilities: %{avif: true}) == :ok
    end

    test "automatic mode is always capable (resolution handles fallback)" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{},
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip
      }

      assert Policy.ensure_capable(policy, output_capabilities: %{avif: false}) == :ok
    end
  end

  describe "effective_quality default resolution" do
    defp policy_for(format, opts) do
      output = struct(%Output{mode: {:explicit, format}}, opts)
      Policy.from_output_plan(%Plug.Conn{}, output, [])
    end

    test "format in format_qualities wins" do
      policy =
        policy_for(:avif, format_qualities: %{avif: {:quality, 63}}, default_quality: {:quality, 80})

      assert {:ok, %{quality: {:quality, 63}}} = Policy.resolve(policy, nil)
    end

    test "format absent from map falls to the global default" do
      policy =
        policy_for(:jpeg, format_qualities: %{avif: {:quality, 63}}, default_quality: {:quality, 80})

      assert {:ok, %{quality: {:quality, 80}}} = Policy.resolve(policy, nil)
    end

    test "png is gated off the global default (stays lossless)" do
      policy = policy_for(:png, default_quality: {:quality, 80})
      assert {:ok, %{quality: :default}} = Policy.resolve(policy, nil)
    end

    test "explicit URL q wins for all formats incl png" do
      policy = policy_for(:png, quality: {:quality, 50}, default_quality: {:quality, 80})
      assert {:ok, %{quality: {:quality, 50}}} = Policy.resolve(policy, nil)
    end
  end

  describe "autoquality bracket precedence (resolve_search)" do
    alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

    defp resolve_search_for(format, search) do
      output = %Output{mode: {:explicit, format}, quality_search: search}
      policy = Policy.from_output_plan(%Plug.Conn{}, output, [])
      {:ok, resolved} = Policy.resolve(policy, nil)
      resolved.quality_search
    end

    test "URL min/max beat per-format config" do
      search = %QualitySearch.Ssimulacra2{
        target: 78,
        min_quality: 70,
        max_quality: 80,
        url_min_quality: 75,
        url_max_quality: 85,
        format_min: %{avif: 60},
        format_max: %{avif: 65}
      }

      assert %RQS.Ssimulacra2{min_quality: 75, max_quality: 85} = resolve_search_for(:avif, search)
    end

    test "per-format config beats base when URL omits" do
      search = %QualitySearch.Ssimulacra2{
        target: 78,
        min_quality: 70,
        max_quality: 80,
        format_min: %{avif: 60},
        format_max: %{avif: 65}
      }

      assert %RQS.Ssimulacra2{min_quality: 60, max_quality: 65} = resolve_search_for(:avif, search)
    end

    test "asymmetric: URL min only, max falls to config base" do
      search = %QualitySearch.Ssimulacra2{
        target: 78,
        min_quality: 70,
        max_quality: 80,
        url_min_quality: 75
      }

      assert %RQS.Ssimulacra2{min_quality: 75, max_quality: 80} = resolve_search_for(:jpeg, search)
    end

    test "jpeg_xl butteraugli native path honors URL override" do
      search = %QualitySearch.Butteraugli{
        target: 1.0,
        min_quality: 70,
        max_quality: 80,
        url_min_quality: 50,
        url_max_quality: 90,
        format_min: %{jpeg_xl: 45},
        format_max: %{jpeg_xl: 80}
      }

      assert %RQS.NativeJxlButteraugli{min_quality: 50, max_quality: 90} =
               resolve_search_for(:jpeg_xl, search)
    end
  end
end
