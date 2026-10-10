defmodule ImagePipe.Output.PolicyTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch
  alias ImagePipe.Plan.Output.PngOptions
  alias ImagePipe.Plan.Output.QualitySearch

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

  describe "negotiate/4" do
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

      assert negotiate_alpha(policy, true) ==
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

      assert negotiate_alpha(policy, false) ==
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
        color_profile: :strip,
        encoder_options: %{png: %PngOptions{palette: true}}
      }

      assert negotiate_alpha(policy, false) ==
               %Resolved{
                 format: :jpeg,
                 quality: {:quality, 82},
                 response_headers: [{"vary", "Accept"}],
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip
               }

      assert negotiate_alpha(policy, true) ==
               %Resolved{
                 format: :png,
                 quality: {:quality, 70},
                 response_headers: [{"vary", "Accept"}],
                 strip_metadata: true,
                 keep_copyright: true,
                 color_profile: :strip,
                 encoder_options: %PngOptions{palette: true}
               }
    end
  end

  describe "quality resolution" do
    test "format quality applies when global quality is default" do
      policy =
        policy(%{
          mode: {:explicit, :webp},
          quality: :default,
          format_qualities: %{webp: {:quality, 70}}
        })

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :webp,
                  quality: {:quality, 70},
                  response_headers: [],
                  strip_metadata: true,
                  keep_copyright: true,
                  color_profile: :strip,
                  encoder_options: nil
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

    test "searches each format within its rails" do
      search = %QualitySearch{target: 75.0}

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = avif}} =
               Policy.resolve(policy_with(search, format: :avif), nil)

      assert {avif.min_quality, avif.max_quality} == {20, 90}

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = jpeg}} =
               Policy.resolve(policy_with(search, format: :jpeg), nil)

      assert {jpeg.min_quality, jpeg.max_quality} == {25, 95}
    end

    test "starts each format's search at its calibrated quality for the target" do
      search = %QualitySearch{target: 75.0}

      for {format, start} <- [jpeg: 76, webp: 78, avif: 53] do
        assert {:ok, %Resolved{quality_search: rs}} =
                 Policy.resolve(policy_with(search, format: format), nil)

        assert rs.start_quality == start
      end
    end

    test "extends the calibration past its targets and keeps the start inside the rails" do
      high = %QualitySearch{target: 95.0}

      assert {:ok, %Resolved{quality_search: %{start_quality: 90}}} =
               Policy.resolve(policy_with(high, format: :avif), nil)

      low = %QualitySearch{target: 73.5}

      assert {:ok, %Resolved{quality_search: %{start_quality: 52}}} =
               Policy.resolve(policy_with(low, format: :avif), nil)
    end

    test "carries the target through" do
      search = %QualitySearch{target: 90.0}

      assert {:ok, %Resolved{quality_search: %ResolvedQualitySearch.Ssimulacra2{} = rs}} =
               Policy.resolve(policy_with(search), nil)

      assert rs.target == 90.0
    end

    test "none stays none" do
      assert {:ok, %Resolved{quality_search: :none}} = Policy.resolve(policy_with(:none), nil)
    end

    test "max_bytes is carried through to Resolved" do
      assert {:ok, %Resolved{max_bytes: 51_200}} =
               Policy.resolve(policy_with(:none, max_bytes: 51_200), nil)
    end
  end

  describe "supports_hdr?/2" do
    test "true only when policy is :preserve and the resolved format carries HDR" do
      png = policy(%{mode: {:explicit, :png}, hdr: :preserve})
      jpeg = %{png | mode: {:explicit, :jpeg}}
      tone_map = %{png | hdr: :tone_map}

      # PNG carries HDR
      assert Policy.supports_hdr?(png, :png)
      # tone_map policy never preserves
      refute Policy.supports_hdr?(tone_map, :png)
      # JPEG cannot carry HDR even when preserve is requested
      refute Policy.supports_hdr?(jpeg, :jpeg)
    end

    test "false when the format is only resolvable from the post-transform image (conservative tone-map)" do
      # automatic mode + no modern Accept + modern source → :needs_final_image_alpha → false
      policy = policy(%{mode: :source, hdr: :preserve})

      refute Policy.supports_hdr?(policy, :avif)
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

      assert Policy.ensure_capable(policy, [:jpeg, :png, :webp]) ==
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

      assert Policy.ensure_capable(policy, [:jpeg, :png, :avif]) == :ok
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

      assert Policy.ensure_capable(policy, [:jpeg, :png]) == :ok
    end
  end

  describe "effective_quality default resolution" do
    defp policy_for(format, opts) do
      policy(Map.put(Map.new(opts), :mode, {:explicit, format}))
    end

    test "format in format_qualities wins" do
      policy =
        policy_for(:avif,
          format_qualities: %{avif: {:quality, 63}},
          default_quality: {:quality, 80}
        )

      assert {:ok, %{quality: {:quality, 63}}} = Policy.resolve(policy, nil)
    end

    test "format in format_qualities wins over an explicit quality" do
      policy =
        policy_for(:avif,
          quality: {:quality, 90},
          format_qualities: %{avif: {:quality, 50}},
          default_quality: {:quality, 80}
        )

      assert {:ok, %{quality: {:quality, 50}}} = Policy.resolve(policy, nil)

      assert {:ok, %{quality: {:quality, 90}}} =
               Policy.resolve(%{policy | mode: {:explicit, :webp}}, nil)
    end

    test "format absent from map falls to the global default" do
      policy =
        policy_for(:jpeg,
          format_qualities: %{avif: {:quality, 63}},
          default_quality: {:quality, 80}
        )

      assert {:ok, %{quality: {:quality, 80}}} = Policy.resolve(policy, nil)
    end

    test "png is gated off the global default (stays lossless)" do
      policy = policy_for(:png, default_quality: {:quality, 80})
      assert {:ok, %{quality: :default}} = Policy.resolve(policy, nil)
    end

    test "explicit URL q applies to png only with a palette" do
      policy = policy_for(:png, quality: {:quality, 50}, default_quality: {:quality, 80})
      assert {:ok, %{quality: :default}} = Policy.resolve(policy, nil)

      palette = %{policy | encoder_options: %{png: %PngOptions{palette: true}}}
      assert {:ok, %{quality: {:quality, 50}}} = Policy.resolve(palette, nil)
    end
  end

  defp policy(attrs) do
    struct!(
      Policy,
      Map.merge(
        %{
          mode: :source,
          modern_candidates: [],
          headers: [],
          quality: :default,
          format_qualities: %{},
          strip_metadata: true,
          keep_copyright: true,
          color_profile: :strip
        },
        attrs
      )
    )
  end

  defp negotiate_alpha(policy, alpha?) do
    image = Image.new!(2, 2, color: :red)

    image =
      case alpha? do
        true -> Image.add_alpha!(image, 128)
        false -> image
      end

    assert {:ok, resolved} = Policy.negotiate(policy, :tiff, image, [])
    resolved
  end
end
