defmodule ImagePipe.Output.PolicyIdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Color
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
    defp format_gen, do: member_of([:avif, :webp, :jpeg_xl, :jpeg, :png])

    defp modern_candidates_gen do
      map(list_of(member_of([:avif, :webp, :jpeg_xl]), max_length: 3), &Enum.uniq/1)
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

  describe "identity_material/1" do
    test "carries the byte-affecting fields, canonicalized" do
      policy = %{
        base_policy()
        | quality: {:quality, 80},
          format_qualities: %{avif: {:quality, 50}},
          default_quality: {:quality, 70},
          strip_metadata: false,
          keep_copyright: false,
          color_profile: :keep,
          hdr: :preserve,
          flatten_background: Color.white(),
          max_bytes: 1000,
          quality_search: :none,
          encoder_options: %{}
      }

      material = Policy.identity_material(policy)

      assert Keyword.fetch!(material, :quality) == {:quality, 80}
      assert Keyword.fetch!(material, :default_quality) == {:quality, 70}
      assert Keyword.fetch!(material, :format_qualities) == %{avif: {:quality, 50}}
      assert Keyword.fetch!(material, :max_bytes) == 1000
      assert Keyword.fetch!(material, :strip_metadata) == false
      assert Keyword.fetch!(material, :keep_copyright) == false
      assert Keyword.fetch!(material, :color_profile) == :keep
      assert Keyword.fetch!(material, :hdr) == :preserve
      assert Keyword.fetch!(material, :quality_search) == :none
      assert Keyword.fetch!(material, :quality_search_offsets) == policy.quality_search_offsets
      assert Keyword.fetch!(material, :flatten_background) == Color.key_data(Color.white())
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
      search = %QualitySearch.Ssimulacra2{
        target: 78.0,
        min_quality: 1,
        max_quality: 100,
        allowed_error: 1.0,
        format_min: %{avif: 1, webp: 2},
        format_max: %{}
      }

      policy = %{base_policy() | quality_search: search}
      material = Policy.identity_material(policy)

      quality_search_material = Keyword.fetch!(material, :quality_search)
      refute is_struct(quality_search_material)
      assert Keyword.fetch!(quality_search_material, :metric) == :ssimulacra2
      assert Keyword.fetch!(quality_search_material, :format_min) == [avif: 1, webp: 2]
    end

    test "encoder_options structs are flattened so they can safely reach a digest" do
      policy = %{
        base_policy()
        | encoder_options: %{jpeg_xl: %ImagePipe.Plan.Output.JxlOptions{effort: 4}}
      }

      material = Policy.identity_material(policy)
      encoder_options_material = Keyword.fetch!(material, :encoder_options)

      refute is_struct(encoder_options_material.jpeg_xl)
      assert encoder_options_material.jpeg_xl.effort == 4
    end
  end
end
