defmodule ImagePipe.Output.PolicyIdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Output.QualitySearch

  defp base_policy do
    %Policy{
      mode: {:explicit, :jpeg},
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{},
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  describe "identity_selection/1" do
    test "explicit mode selects the explicit format" do
      policy = %{base_policy() | mode: {:explicit, :avif}}
      assert Policy.identity_selection(policy) == {:explicit, :avif}
    end

    test "source mode with modern candidates selects the head" do
      policy = %{base_policy() | mode: :source, modern_candidates: [:avif, :webp]}
      assert Policy.identity_selection(policy) == {:auto_head, :avif}
    end

    test "source mode with no modern candidates defers to source negotiation" do
      policy = %{base_policy() | mode: :source, modern_candidates: []}
      assert Policy.identity_selection(policy) == :source_negotiated
    end
  end

  describe "encode-agreement property" do
    defp format_gen, do: member_of([:avif, :webp, :jpeg, :png])

    defp modern_candidates_gen do
      map(list_of(member_of([:avif, :webp]), max_length: 3), &Enum.uniq/1)
    end

    defp source_format_gen,
      do: one_of([constant(nil), member_of([:jpeg, :png, :webp, :avif, :heif, :tiff, :jpeg_xl])])

    defp policy_gen do
      gen all mode <- one_of([map(format_gen(), &{:explicit, &1}), constant(:source)]),
              modern_candidates <- modern_candidates_gen() do
        %{
          base_policy()
          | mode: mode,
            modern_candidates: if(mode == :source, do: modern_candidates, else: [])
        }
      end
    end

    property "identity_selection/1 agrees with resolve/2 whenever it names a concrete format" do
      check all policy <- policy_gen(),
                source_format <- source_format_gen(),
                max_runs: 100 do
        case Policy.identity_selection(policy) do
          {:explicit, format} ->
            assert {:ok, %Resolved{format: ^format}} = Policy.resolve(policy, source_format)

          {:auto_head, format} ->
            assert {:ok, %Resolved{format: ^format}} = Policy.resolve(policy, source_format)

          :source_negotiated ->
            # resolve/2's outcome here depends on source_format, which
            # identity_selection/1 deliberately does not name — nothing to
            # check against a concrete format.
            :ok
        end
      end
    end
  end

  describe "identity_material/1 for a format chosen before the fetch" do
    defp quality_gen,
      do: one_of([constant(:default), map(member_of([40, 60, 80]), &{:quality, &1})])

    defp format_qualities_gen do
      map(list_of(tuple({format_gen(), map(member_of([40, 60]), &{:quality, &1})})), &Map.new/1)
    end

    defp encoder_options_gen do
      gen all avif_effort <- member_of([3, 6]),
              webp_effort <- member_of([4, 6]),
              palette <- boolean(),
              interlace <- boolean() do
        %{
          avif: %ImagePipe.Plan.Output.AvifOptions{effort: avif_effort},
          webp: %ImagePipe.Plan.Output.WebpOptions{effort: webp_effort},
          png: %ImagePipe.Plan.Output.PngOptions{palette: palette},
          jpeg: %ImagePipe.Plan.Output.JpegOptions{interlace: interlace}
        }
      end
    end

    # A URL's per-format quality fixes it and turns its search off. A host's
    # per-format quality, such as the default AVIF one, doesn't.
    defp fixed_quality_formats(format_qualities, true),
      do: format_qualities |> Map.keys() |> Enum.sort()

    defp fixed_quality_formats(_format_qualities, false), do: []

    defp selection_gen do
      one_of([
        map(format_gen(), &{{:explicit, &1}, []}),
        map(member_of([[:avif, :webp], [:webp]]), &{:source, &1})
      ])
    end

    defp chosen_policy_gen(selection) do
      gen all quality <- quality_gen(),
              strip_metadata <- boolean(),
              dpi <- member_of([nil, 72]),
              color_profile <- member_of([:strip, :keep]),
              hdr <- member_of([:tone_map, :preserve]),
              max_bytes <- member_of([nil, 10_000]),
              skip_formats <- member_of([[], [:png]]),
              fix_every_quality <- boolean(),
              default_quality <- member_of([{:quality, 70}, {:quality, 80}]),
              format_qualities <- format_qualities_gen(),
              encoder_options <- encoder_options_gen(),
              search <-
                one_of([
                  constant(:none),
                  map(member_of([75.0, 80.0]), &%QualitySearch{target: &1})
                ]) do
        {mode, modern_candidates} = selection

        %{
          base_policy()
          | mode: mode,
            modern_candidates: modern_candidates,
            quality: quality,
            default_quality: default_quality,
            format_qualities: format_qualities,
            fixed_quality_formats: fixed_quality_formats(format_qualities, fix_every_quality),
            encoder_options: encoder_options,
            quality_search: search,
            strip_metadata: strip_metadata,
            dpi: dpi,
            color_profile: color_profile,
            hdr: hdr,
            max_bytes: max_bytes,
            skip_formats: skip_formats
        }
      end
    end

    @varied_fields [
      :quality,
      :default_quality,
      :format_qualities,
      :fixed_quality_formats,
      :encoder_options,
      :quality_search,
      :strip_metadata,
      :dpi,
      :color_profile,
      :hdr,
      :max_bytes,
      :skip_formats
    ]

    # Delivery reads the HDR policy and the skip-processing formats from the
    # policy itself, alongside the resolved encode.
    defp encode(policy), do: {Policy.resolve(policy, nil), policy.hdr, policy.skip_formats}

    property "two policies have the same material exactly when they encode the same way" do
      check all selection <- selection_gen(),
                a <- chosen_policy_gen(selection),
                other <- chosen_policy_gen(selection),
                fields <- list_of(member_of(@varied_fields), min_length: 1, max_length: 2),
                max_runs: 500 do
        # Independent policies almost never agree on everything but one
        # setting, so `b` is `a` with one or two settings taken from `other`.
        b = struct!(a, Map.take(Map.from_struct(other), fields))
        same_encode = encode(a) == encode(b)
        same_material = Policy.identity_material(a) == Policy.identity_material(b)
        assert same_material == same_encode
      end
    end
  end

  describe "identity_material/1 for a chosen format's settings" do
    test "holds that format's encoder options and search, flattened" do
      policy = %{
        base_policy()
        | mode: {:explicit, :avif},
          encoder_options: %{
            avif: %ImagePipe.Plan.Output.AvifOptions{effort: 4},
            webp: %ImagePipe.Plan.Output.WebpOptions{effort: 6}
          },
          quality_search: %QualitySearch{target: 78.0}
      }

      material = Policy.identity_material(policy)

      encoder_options = Keyword.fetch!(material, :encoder_options)
      refute is_struct(encoder_options)
      assert encoder_options.effort == 4

      quality_search = Keyword.fetch!(material, :quality_search)
      refute is_struct(quality_search)
      assert quality_search.target == 78.0
    end
  end

  describe "identity_material/1 and the search pixel limit" do
    test "enters identity only when the request searches" do
      for mode <- [{:explicit, :avif}, :source] do
        plain = %{base_policy() | mode: mode, max_search_pixels: 1_000}

        refute Keyword.has_key?(Policy.identity_material(plain), :max_search_pixels)

        for searching <- [
              %{plain | quality_search: %QualitySearch{target: 78.0}},
              %{plain | max_bytes: 1_000}
            ] do
          assert Keyword.fetch!(Policy.identity_material(searching), :max_search_pixels) == 1_000
        end
      end
    end

    test "drops out with lossless WebP, which has no quality to search" do
      policy = %{
        base_policy()
        | mode: {:explicit, :webp},
          encoder_options: %{webp: %ImagePipe.Plan.Output.WebpOptions{lossless: true}},
          max_bytes: 1_000,
          max_search_pixels: 1_000
      }

      refute Keyword.has_key?(Policy.identity_material(policy), :max_search_pixels)
    end
  end

  describe "identity_material/1 for a format chosen after the fetch" do
    defp source_negotiated_policy, do: %{base_policy() | mode: :source}

    test "carries the byte-affecting fields, canonicalized" do
      policy = %{
        source_negotiated_policy()
        | quality: {:quality, 80},
          format_qualities: %{avif: {:quality, 50}},
          default_quality: {:quality, 70},
          strip_metadata: false,
          keep_copyright: false,
          color_profile: :keep,
          hdr: :preserve,
          max_bytes: 1000,
          dpi: 300,
          quality_search: :none,
          encoder_options: %{}
      }

      material = Policy.identity_material(policy)

      assert Keyword.fetch!(material, :quality) == {:quality, 80}
      assert Keyword.fetch!(material, :default_quality) == {:quality, 70}
      assert Keyword.fetch!(material, :format_qualities) == %{avif: {:quality, 50}}
      assert Keyword.fetch!(material, :max_bytes) == 1000
      assert Keyword.fetch!(material, :dpi) == 300
      assert Keyword.fetch!(material, :strip_metadata) == false
      assert Keyword.fetch!(material, :keep_copyright) == false
      assert Keyword.fetch!(material, :color_profile) == :keep
      assert Keyword.fetch!(material, :hdr) == :preserve
      assert Keyword.fetch!(material, :quality_search) == :none
      assert Keyword.fetch!(material, :encoder_options) == %{}
    end

    test "excludes mode, modern_candidates, and headers" do
      policy = %{
        base_policy()
        | mode: :source,
          modern_candidates: [:avif],
          headers: [{"vary", "Accept"}]
      }

      material = Policy.identity_material(policy)

      refute Keyword.has_key?(material, :mode)
      refute Keyword.has_key?(material, :modern_candidates)
      refute Keyword.has_key?(material, :headers)
    end

    test "two policies differing only in default_quality produce different material" do
      a = %{base_policy() | default_quality: {:quality, 70}}
      b = %{base_policy() | default_quality: {:quality, 90}}

      assert Policy.identity_material(a) != Policy.identity_material(b)
    end

    test "quality_search struct is flattened so it can safely reach a digest" do
      search = %QualitySearch{target: 78.0}

      policy = %{source_negotiated_policy() | quality_search: search}
      material = Policy.identity_material(policy)

      quality_search_material = Keyword.fetch!(material, :quality_search)
      refute is_struct(quality_search_material)
      assert quality_search_material == [target: 78.0]
    end

    test "encoder_options structs are flattened so they can safely reach a digest" do
      policy = %{
        source_negotiated_policy()
        | encoder_options: %{avif: %ImagePipe.Plan.Output.AvifOptions{effort: 4}}
      }

      material = Policy.identity_material(policy)
      encoder_options_material = Keyword.fetch!(material, :encoder_options)

      refute is_struct(encoder_options_material.avif)
      assert encoder_options_material.avif.effort == 4
    end
  end
end
