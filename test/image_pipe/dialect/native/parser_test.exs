defmodule ImagePipe.Dialect.Native.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.Native.Diagnostic
  alias ImagePipe.Dialect.Native.DiagnosticRenderer
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output

  # `parse/2` consumes Task 4's lexed map directly — never a conn — so
  # tests build that map by hand instead of going through `Path.extract/1`.
  # Span *values* only matter for diagnostic assertions; success-path
  # assertions don't depend on them.
  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source) do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp parse(segments, source \\ "images/cat.jpg", config \\ []) do
    Parser.parse(lexed(segments, source), config)
  end

  describe "worked examples [native §Examples]" do
    test "srcset workhorse: /w=800/src/images/cat.jpg" do
      assert {:ok, request} = parse(["w=800"])

      assert request == %Request{
               groups: [
                 %Group{resize: %{w: 800, h: :auto, fit: :contain, enlarge: false}}
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "fill a box from a focal point, force webp" do
      assert {:ok, request} =
               parse(["fit=cover", "w=300", "h=400", "focus=0.25,0.75", "format=webp"])

      assert request == %Request{
               groups: [
                 %Group{
                   resize: %{w: 300, h: 400, fit: :cover, enlarge: false},
                   guide: {:focus, 0.25, 0.75}
                 }
               ],
               output: %Output{terminal: :image, format: :webp, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "explicit smart crop, then resize down" do
      assert {:ok, request} = parse(["crop=600,400", "anchor=smart", "w=300"])

      assert request == %Request{
               groups: [
                 %Group{
                   crop: {{:px, 600}, {:px, 400}},
                   guide: {:anchor_smart},
                   resize: %{w: 300, h: :auto, fit: :contain, enlarge: false}
                 }
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "cheap trim: resize first, trim the small image" do
      assert {:ok, request} = parse(["w=500", "then", "trim=fff"])

      assert request == %Request{
               groups: [
                 %Group{resize: %{w: 500, h: :auto, fit: :contain, enlarge: false}},
                 %Group{trim: {{255, 255, 255}, 10}}
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "trim=color defaults its tolerance to 10, canonically equal to explicit ,10" do
      assert {:ok, defaulted} = parse(["trim=fff"])
      assert {:ok, explicit} = parse(["trim=fff,10"])

      assert [%Group{trim: {{255, 255, 255}, 10}}] = defaulted.groups
      # Same canonical request as the explicit spelling -> same cache key/ETag.
      assert defaulted == explicit
      # A different tolerance must NOT collapse onto the default.
      assert {:ok, other} = parse(["trim=fff,5"])
      refute defaulted == other
    end

    test "relative crop with explicit units" do
      assert {:ok, request} = parse(["crop=80pct,60pct"])

      assert request == %Request{
               groups: [
                 %Group{
                   crop: {{:pct, 80}, {:pct, 60}},
                   guide: {:anchor, :center}
                 }
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "blurhash placeholder terminal (no format/quality)" do
      assert {:ok, request} = parse(["w=32", "output=blurhash"])

      assert request == %Request{
               groups: [
                 %Group{resize: %{w: 32, h: :auto, fit: :contain, enlarge: false}}
               ],
               output: %Output{terminal: :blurhash, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end
  end

  describe "happy path per option" do
    test "w alone builds a resize with h defaulted to auto" do
      assert {:ok, %Request{groups: [%Group{resize: %{w: 800, h: :auto}}]}} = parse(["w=800"])
    end

    test "h alone builds a resize with w defaulted to auto" do
      assert {:ok, %Request{groups: [%Group{resize: %{w: :auto, h: 600}}]}} = parse(["h=600"])
    end

    test "fit with a resize intent" do
      assert {:ok, %Request{groups: [%Group{resize: %{fit: :stretch}}]}} =
               parse(["w=800", "fit=stretch"])
    end

    test "enlarge with a resize intent" do
      assert {:ok, %Request{groups: [%Group{resize: %{enlarge: true}}]}} =
               parse(["w=800", "enlarge"])
    end

    test "crop alone defaults its guide to anchor=center" do
      assert {:ok,
              %Request{
                groups: [%Group{crop: {{:px, 600}, {:px, 400}}, guide: {:anchor, :center}}]
              }} =
               parse(["crop=600,400"])
    end

    test "region needs no guide" do
      assert {:ok,
              %Request{
                groups: [%Group{region: {{:px, 0}, {:px, 0}, {:px, 600}, {:px, 400}}, guide: nil}]
              }} =
               parse(["region=0,0,600,400"])
    end

    test "anchor with a crop consumer" do
      assert {:ok, %Request{groups: [%Group{guide: {:anchor, :top_left}}]}} =
               parse(["crop=600,400", "anchor=top-left"])
    end

    test "focus with a cover-fit resize consumer" do
      assert {:ok, %Request{groups: [%Group{guide: {:focus, 0.1, 0.2}}]}} =
               parse(["w=300", "fit=cover", "focus=0.1,0.2"])
    end

    test "blur with a non-zero sigma" do
      assert {:ok, %Request{groups: [%Group{blur: 3.0}]}} = parse(["blur=3"])
    end

    test "trim=auto" do
      assert {:ok, %Request{groups: [%Group{trim: :auto}]}} = parse(["trim=auto"])
    end

    test "pad shorthand" do
      assert {:ok, %Request{groups: [%Group{pad: {10, 20, 10, 20}}]}} = parse(["pad=10,20"])
    end

    test "bg with alpha" do
      assert {:ok, %Request{groups: [%Group{bg: {255, 255, 255, 0.5}}]}} =
               parse(["bg=fff,0.5"])
    end

    test "output=image is the identity default, stated explicitly" do
      assert {:ok, %Request{output: %Output{terminal: :image}}} = parse(["output=image"])
    end

    test "format alone (negotiated output)" do
      assert {:ok, %Request{output: %Output{format: :avif}}} = parse(["format=avif"])
    end

    test "q alone" do
      assert {:ok, %Request{output: %Output{quality: 80}}} = parse(["q=80"])
    end

    test "expires as a gate field" do
      assert {:ok, %Request{expires: 1_999_999_999}} = parse(["expires=1999999999"])
    end

    test "an overridden-away preset is grammar-validated but never reaches the canonical request" do
      config = [presets: %{"card" => "w=999"}]

      assert {:ok, with_preset} = parse(["preset=card", "w=800"], "images/cat.jpg", config)
      assert {:ok, without_preset} = parse(["w=800"])
      assert with_preset == without_preset
    end

    test "an invalid preset name is still a 400" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["preset=bad!name", "w=800"])
      assert Enum.any?(diagnostics, &(&1.reason == :invalid_preset_name))
    end
  end

  describe "400s: unknown key / invalid value" do
    test "unknown key" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["bogus=10"])
      assert Enum.any?(diagnostics, &(&1.reason == :unknown_option))
    end

    test "invalid value for a known key" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=notanumber"])
      assert Enum.any?(diagnostics, &(&1.reason == :invalid_dimension))
    end

    test "key=true is a specific error, not a generic invalid value" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "enlarge=true"])
      assert Enum.any?(diagnostics, &(&1.reason == :true_spelled_bare))
    end

    test "errors accumulate across independent violations" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["bogus=10", "w=notanumber"])
      reasons = Enum.map(diagnostics, & &1.reason)
      assert :unknown_option in reasons
      assert :invalid_dimension in reasons
    end
  end

  describe "400s: duplicates [native §Scoping and duplicates]" do
    test "group-scoped key twice in a group" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "w=900"])
      assert Enum.any?(diagnostics, &(&1.reason == :duplicate_option))
    end

    test "duplicate diagnostic carries every participating span" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "w=900"])

      assert %{reason: :duplicate_option, spans: spans} =
               Enum.find(diagnostics, &(&1.reason == :duplicate_option))

      assert length(spans) == 2
    end

    test "request-scoped key twice anywhere in the URL" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["format=webp", "w=800", "then", "format=avif"])

      assert Enum.any?(diagnostics, &(&1.reason == :duplicate_option))
    end

    test "the same key in different groups is not a duplicate" do
      assert {:ok, _request} = parse(["w=800", "then", "w=400"])
    end
  end

  describe "400s: Tier-3 mutually exclusive pairs" do
    test "focus and anchor in the same group" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "anchor=center", "focus=0.5,0.5"])

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
    end

    test "crop and region in the same group" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "region=0,0,600,400"])

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
    end
  end

  describe "400s: Tier-2 inertness (locked probe decisions)" do
    test "fit without a resize intent is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["fit=cover"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "enlarge without a resize intent is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["enlarge"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "a lone auto dimension is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=auto"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "a doubled auto dimension is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=auto", "h=auto"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "anchor without a consumer is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["anchor=center"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "focus without a consumer is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["focus=0.5,0.5"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "anchor with a contain-fit resize is still inert (not a guide consumer)" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "anchor=center"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "fit=auto counts as a valid guide consumer at parse time" do
      assert {:ok, %Request{groups: [%Group{guide: {:anchor, :center}}]}} =
               parse(["w=800", "fit=auto"])
    end

    test "format with output=blurhash is inert" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=32", "output=blurhash", "format=webp"])

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "q with output=blurhash is inert" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=32", "output=blurhash", "q=80"])

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end
  end

  describe "400s: Tier-2 inertness derivative-error suppression [native §Error diagnostics]" do
    test "a present-but-invalid w suppresses enlarge's own inertness complaint" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=invalid", "enlarge"])
      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid w suppresses fit's own inertness complaint" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=invalid", "fit=cover"])
      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid crop suppresses anchor's own inertness complaint" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=abc,def", "anchor=top-left"])

      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_element in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid w suppresses focus's own inertness complaint (guide consumer via cover-fit)" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["fit=cover", "w=invalid", "focus=0.5,0.5"])

      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "a genuinely absent prerequisite still triggers the dependent's inertness (no w/h at all)" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["enlarge"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end
  end

  describe "400s: empty pipeline groups" do
    test "leading then" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["then", "w=800"])
      assert Enum.any?(diagnostics, &(&1.reason == :empty_pipeline_group))
    end

    test "trailing then" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "then"])
      assert Enum.any?(diagnostics, &(&1.reason == :empty_pipeline_group))
    end

    test "doubled then" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=800", "then", "then", "h=400"])

      assert Enum.any?(diagnostics, &(&1.reason == :empty_pipeline_group))
    end

    test "no then at all is a single, legitimately-empty group and is not an error" do
      assert {:ok, %Request{groups: [%Group{}]}} = parse([])
    end
  end

  describe "parse_option_fragment/2" do
    defp fragment(string), do: Parser.parse_option_fragment(string, [])

    test "parses a group-scoped-only fragment into a clean map" do
      assert fragment("w=800/fit=cover") == {:ok, %{"w" => 800, "fit" => :cover}}
    end

    test "rejects a then segment" do
      assert {:error, diagnostics} = fragment("w=800/then/h=400")
      assert Enum.any?(diagnostics, &(&1.reason == :then_not_allowed_in_fragment))
    end

    test "rejects a src segment" do
      assert {:error, diagnostics} = fragment("w=800/src")
      assert Enum.any?(diagnostics, &(&1.reason == :source_not_allowed_in_fragment))
    end

    test "rejects a request-scoped key" do
      assert {:error, diagnostics} = fragment("w=800/format=webp")
      assert Enum.any?(diagnostics, &(&1.reason == :request_scoped_key_in_fragment))
    end

    test "rejects an unknown key" do
      assert {:error, diagnostics} = fragment("bogus=1")
      assert Enum.any?(diagnostics, &(&1.reason == :unknown_option))
    end

    test "rejects a duplicate key within the fragment" do
      assert {:error, diagnostics} = fragment("w=800/w=900")
      assert Enum.any?(diagnostics, &(&1.reason == :duplicate_option))
    end

    test "does not run cross-option (Tier 2/3) validation" do
      # `anchor` alone has no consumer within this fragment, but that is a
      # decision for the merged request, not this narrow surface.
      assert fragment("anchor=smart") == {:ok, %{"anchor" => :smart}}
    end
  end

  describe "presets [native §Presets, trimmed to probe]" do
    test "a named preset contributes options the URL never states" do
      config = [presets: %{"card" => "w=300/fit=cover"}]

      assert {:ok, request} = parse(["preset=card"], "images/cat.jpg", config)

      assert %Request{
               groups: [
                 %Group{resize: %{w: 300, h: :auto, fit: :cover, enlarge: false}}
               ]
             } = request
    end

    test "the default preset applies with no preset= segment in the URL at all" do
      config = [presets: %{"default" => "blur=2.5"}]

      assert {:ok, %Request{groups: [%Group{blur: 2.5}]}} =
               parse(["w=800"], "images/cat.jpg", config)
    end

    test "precedence chain: default < named presets in URL order < explicit URL options" do
      config = [
        presets: %{
          "default" => "blur=1",
          "a" => "blur=2/trim=auto",
          "b" => "blur=3"
        }
      ]

      # explicit w=800 is untouched by any level; blur is set by "default",
      # displaced by "a", then displaced again by "b" (last-listed named
      # preset wins); trim survives from "a" since nothing displaces it.
      assert {:ok, request} = parse(["preset=a,b", "w=800"], "images/cat.jpg", config)

      assert %Request{
               groups: [
                 %Group{
                   resize: %{w: 800, h: :auto, fit: :contain, enlarge: false},
                   blur: 3.0,
                   trim: :auto
                 }
               ]
             } = request
    end

    test "an explicit URL option displaces every preset level for that key" do
      config = [presets: %{"default" => "w=100", "card" => "w=300"}]

      assert {:ok, request} = parse(["preset=card", "w=800"], "images/cat.jpg", config)
      assert %Request{groups: [%Group{resize: %{w: 800}}]} = request
    end

    test "an unknown preset name is a 400" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["preset=nope", "w=800"], "images/cat.jpg", presets: %{})

      assert Enum.any?(diagnostics, &(&1.reason == :unknown_preset))
    end

    test "a preset-contributed key can still trigger Tier-2 inertness on the merged group" do
      # `fit=cover` alone (no resize intent from either the preset or the
      # URL) is inert — cross-option validation runs over the *merged*
      # group, not just the URL's own explicit segments.
      config = [presets: %{"cover" => "fit=cover"}]

      assert {:error, {:invalid_request, diagnostics}} =
               parse(["preset=cover"], "images/cat.jpg", config)

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "a preset combined with an explicit dimension satisfies its own inertness prerequisite" do
      config = [presets: %{"cover" => "fit=cover"}]

      assert {:ok, %Request{groups: [%Group{resize: %{fit: :cover}}]}} =
               parse(["preset=cover", "w=800"], "images/cat.jpg", config)
    end

    test "a default-preset-only inertness diagnostic anchors to the whole raw path, not {0, 0}" do
      # No `preset=` segment at all — the `default` preset applies purely
      # from config, so there is no real segment for the resulting
      # cross-option diagnostic to anchor to. It must fall back to the
      # whole raw path, not a zero-length {0, 0} span.
      config = [presets: %{"default" => "fit=cover"}]
      raw_path = "/src/images/cat.jpg"
      lexed = %{segments: [], source: {:src, "images/cat.jpg", {5, 14}}}

      assert {:error, {:invalid_request, diagnostics}} = Parser.parse(lexed, config)

      assert [%Diagnostic{reason: :inert_option, spans: [{0, 19}]}] = diagnostics
      assert byte_size(raw_path) == 19

      rendered =
        raw_path
        |> DiagnosticRenderer.render(diagnostics)
        |> IO.iodata_to_binary()

      assert rendered =~ String.duplicate("^", 19)
    end

    test "a host preset literally named `default` combined with an explicit preset=default is idempotent" do
      config = [presets: %{"default" => "blur=2"}]

      assert {:ok, applied_once} = parse(["w=800"], "images/cat.jpg", config)

      assert {:ok, applied_explicitly} =
               parse(["preset=default", "w=800"], "images/cat.jpg", config)

      assert applied_once == applied_explicitly
    end

    property "an overridden-away preset never changes the canonical %Request{}" do
      check all preset_w <- StreamData.integer(1..4000),
                url_w <- StreamData.integer(1..4000) do
        config = [presets: %{"card" => "w=#{preset_w}"}]

        assert parse(["preset=card", "w=#{url_w}"], "images/cat.jpg", config) ==
                 parse(["w=#{url_w}"])
      end
    end
  end
end
