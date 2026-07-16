# Credo configuration. Modeled on VibeKit's minimal template: rely on Credo's
# default check set plus plugin-provided checks, and list only overrides here.
#
# IMPORTANT: keep `checks` a plain list of overrides. An explicit
# `checks: %{enabled: [...]}` map *replaces* the accumulated base config and
# silently drops plugin-registered checks (ExSlop), per Credo's merge rules.
%{
  configs: [
    %{
      name: "default",
      #
      # ExSlop: catches AI-generated code slop; its plugin enables ~31
      #   recommended high-signal checks. See https://hex.pm/packages/ex_slop.
      # ExDNA.Credo: AST-aware duplicate detection; replaces the built-in
      #   Credo.Check.Design.DuplicatedCode. `alias` is excluded (see checks
      #   below) so runs of `alias`/`as:` declarations — which `AliasOrder`
      #   forces into a fixed order and which sibling modules in one namespace
      #   legitimately overlap — are not counted as logic clones.
      #
      plugins: [{ExSlop, []}, {ExDNA.Credo, []}],
      checks: [
        #
        # ExSlop-recommended built-ins not in Credo's default set, enabled here.
        #
        {Credo.Check.Refactor.DoubleBooleanNegation, []},
        {Credo.Check.Refactor.MapMap, []},
        #
        # Disabled — every occurrence in this codebase is a deliberate idiom, not
        # the anti-pattern the check targets:
        #   - AppendSingleItem (left unenabled): compile-time
        #     `defstruct @enforce_keys ++ [defaults]`, single appends to small
        #     order-significant lists, and event-name building — never a hot
        #     loop accumulator.
        #   - LengthComparison: arity guards (`when length(x) <= n`, where the
        #     suggested Enum.count_until/2 isn't guard-safe) and exact-count test
        #     assertions — never the `length(x) == 0` empty check it flags.
        #
        {ExSlop.Check.Refactor.LengthComparison, false},
        # ExDNA duplicate detection, excluding `alias` declarations (see plugins
        # note above). `ignore:` excludes ImagePipe.Decode's deliberate mirror of
        # ImagePipe.Request.Processor / Request.SourceFormat (the dialect-owned
        # fetch/decode bracket cannot depend on the Request boundary, so the
        # two-open decode flow and the loader-name->format classification are
        # duplicated by hand rather than shared — see the module docs in
        # lib/image_pipe/decode.ex and lib/image_pipe/decode/source_format.ex,
        # and the Task 21.6 core-exports report). ExDNA reports a duplicate pair
        # from both anchor files, and lib/image_pipe/request/processor.ex stays
        # untouched (framework-frozen), so the pair can only be silenced by
        # excluding the Decode-side files from the corpus entirely.
        #
        # ImagePipe.Dialect.Native.Pipeline also deliberately mirrors two small
        # private helpers off ImagePipe.Transform.Executor (`overlay/2` and
        # `boundary_source_dimensions/1`) — Executor is not exported from the
        # Transform boundary and is core-frozen for this task, so the dialect's
        # own resolve-loop driver cannot call it; see the module doc in
        # lib/image_pipe/dialect/native/pipeline.ex and the Task 14 report.
        #
        # ImagePipe.Response.Conditional deliberately duplicates the private
        # If-None-Match parsing/matching helpers in
        # ImagePipe.Request.HTTPCache (if_none_match?/2, parse_if_none_match/1)
        # so a dialect can evaluate a conditional GET before any cache lookup
        # without depending on the Request boundary (HTTPCache is
        # framework-frozen). See the module doc in
        # lib/image_pipe/response/conditional.ex and the Task 16 report.
        # Ignored for the same reason as the pairs above.
        #
        # The ImagePipe.Dialect.Imgproxy.* leaf request structs and grammar
        # modules are near-verbatim phase-1 copies of their
        # ImagePipe.Parser.Imgproxy.* originals: the inverted dialect owns its
        # whole request chain and grammar and may not depend on the Parser
        # boundary, and the framework originals stay frozen while both arms run
        # side by side. Unlike the blessed mirrors above this duplication is
        # TRANSIENT — the originals are deleted in phase 2, at which point these
        # entries go with them (phase-1 dialect copy, retired in phase 2 per spec
        # 2026-07-15).
        #
        # ImagePipe.Dialect.Imgproxy.Pipeline mirrors Transform.Executor's private
        # overlay/2 and boundary_source_dimensions/1 for the same blessed reason
        # Native.Pipeline does (Executor is not exported from the Transform
        # boundary and is core-frozen, so a dialect's own resolve-loop driver
        # cannot call it), and carries the verbatim copy of
        # Parser.Imgproxy.Resolver's padding/DPR carry arithmetic.
        #
        # ImagePipe.Dialect.Imgproxy.Assembly is the phase-1 copy of frozen
        # Parser.Imgproxy.PlanBuilder's geometry half (plan_geometry/1 and every
        # private helper it reaches). Transient like the leaf structs: retired in
        # phase 2 when the framework original is deleted.
        #
        # ImagePipe.Dialect.Imgproxy.Config's source_schemes validation
        # (validate_source_schemes/1, valid_source_scheme_entry?/1,
        # valid_source_scheme_translator?/1) is the same transient phase-1 copy
        # of frozen Parser.Imgproxy's equivalent private helpers (the dialect
        # cannot depend on the Parser boundary). The Config module's own
        # `storage_inputs` validator is NOT duplicated — it delegates to the
        # newly-shared ImagePipe.Dialect.SharedConfig.validate_storage_input/1,
        # which ImagePipe.Dialect.Native.Config now also delegates to instead of
        # carrying its own copy.
        #
        # ImagePipe.Dialect.Imgproxy.Identity.color_profile_policy/2 and
        # hdr_policy/1 are verbatim copies of the frozen
        # Parser.Imgproxy.PlanBuilder's private helpers of the same name (not
        # exported, and the dialect cannot depend on the Parser boundary).
        # Transient like the other phase-1 copies above.
        #
        # ImagePipe.Dialect.Imgproxy.ResponseMeta is the phase-1 copy of frozen
        # Parser.Imgproxy.PlanBuilder's response_plan/2 and the
        # source_filename/1 family it reaches. Transient like the other
        # phase-1 copies: retired in phase 2 with the framework original.
        #
        # ImagePipe.Dialect.Imgproxy.InfoRenderer is the phase-1 copy of frozen
        # Parser.Imgproxy.InfoRenderer (the /info wire table and JSON doc),
        # minus the ImagePipe.Renderer behaviour the dialect cannot depend on.
        # Transient like the other phase-1 copies.
        #
        # ImagePipe.Dialect.Imgproxy is the dialect's Plug chain, and mirrors
        # ImagePipe.Dialect.Native's chain shape (negotiate/3's policy branch,
        # generate's Delivery.stream case, resolve_output/3, cache_headers/1 +
        # vary_headers/1, the result-limit defaults).
        #
        # The mirrored pairs here are NOT all blessed for the same reason, and
        # this entry silences a ~650-line module that is still growing — so the
        # two classes are recorded separately. Do not read this entry as "nothing
        # in this file is extractable".
        #
        # Tracked: hlindset/image_pipe#457 — promote the extractable helpers and
        # settle the ExDNA-visibility strategy as one boundary-graph ADR during
        # the TwicPics inversion (the visibility goal is unreachable at N=2: the
        # ignore is file-level and the structural mirrors below cannot be shared).
        #
        # (a) NOT shareable as the graph stands. cache_headers/1 + vary_headers/1
        #     build a %CacheHeaders{} (ImagePipe.Response) from a
        #     %Representation{}, and ImagePipe.Response does not depend on
        #     ImagePipe.Representation. Promoting them needs a new Response ->
        #     Representation edge — a core boundary-graph decision, not a
        #     dialect's to make. Declined for now; see the Task R8 report.
        #
        # (b) Extractable TODAY, deferred only because the move would edit
        #     shipped ImagePipe.Dialect.Native. Neither of these needs a new
        #     edge: both dialects already depend on ImagePipe.Output.
        #     - resolve_output/3 touches only Policy.resolve/2,
        #       Policy.resolve_final_image_alpha/2 and Image.has_alpha?/1. THREE
        #       copies exist: here, Native's, and the framework's own
        #       Request.DeliveryBuild.do_resolve_output/3 — that one differing
        #       only in wrapping its error as {:error, {:output, reason}} where
        #       both dialects return it bare.
        #     - result_limits/1 + min_limit/2 touch only Encoder.encoder_limit/1.
        #       Their twin is the framework's DeliveryBuild.effective_limits/2 +
        #       min_limit/2, which is the same function reading the host caps
        #       from opts where this reads module attributes. NOTE this pair is
        #       NOT the imgproxy<->native mirror the list above implies: Native's
        #       result_limits/0 takes no format and consults no encoder limit at
        #       all. Only the three @default_max_result_* constants are shared
        #       with Native.
        #
        # The rest (negotiate/3's policy branch, generate's Delivery.stream case)
        # is chain shape between two separate top-level dialect boundaries,
        # NEITHER of which may name the other (a product dialect never depends on
        # another product dialect) — that genuinely cannot be shared by reference.
        {ExDNA.Credo,
         excluded_macros: [:alias],
         ignore: [
           "lib/image_pipe/decode.ex",
           "lib/image_pipe/decode/source_format.ex",
           "lib/image_pipe/dialect/imgproxy.ex",
           "lib/image_pipe/dialect/imgproxy/assembly.ex",
           "lib/image_pipe/dialect/imgproxy/config.ex",
           "lib/image_pipe/dialect/imgproxy/crop_request.ex",
           "lib/image_pipe/dialect/imgproxy/effects.ex",
           "lib/image_pipe/dialect/imgproxy/format.ex",
           "lib/image_pipe/dialect/imgproxy/identity.ex",
           "lib/image_pipe/dialect/imgproxy/info_renderer.ex",
           "lib/image_pipe/dialect/imgproxy/option_grammar.ex",
           "lib/image_pipe/dialect/imgproxy/options.ex",
           "lib/image_pipe/dialect/imgproxy/orientation.ex",
           "lib/image_pipe/dialect/imgproxy/path.ex",
           "lib/image_pipe/dialect/imgproxy/percent_encoding.ex",
           "lib/image_pipe/dialect/imgproxy/pipeline.ex",
           "lib/image_pipe/dialect/imgproxy/pipeline_request.ex",
           "lib/image_pipe/dialect/imgproxy/presets.ex",
           "lib/image_pipe/dialect/imgproxy/request.ex",
           "lib/image_pipe/dialect/imgproxy/response_meta.ex",
           "lib/image_pipe/dialect/imgproxy/signature.ex",
           "lib/image_pipe/dialect/imgproxy/source.ex",
           "lib/image_pipe/dialect/imgproxy/source_encryption.ex",
           "lib/image_pipe/dialect/imgproxy/source_scheme.ex",
           "lib/image_pipe/dialect/native/pipeline.ex",
           "lib/image_pipe/response/conditional.ex"
         ]}
      ]
    }
  ]
}
