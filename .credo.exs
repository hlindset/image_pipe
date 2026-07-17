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
        # ImagePipe.Dialect.Native.Pipeline and ImagePipe.Dialect.Imgproxy.Pipeline
        # each deliberately mirror two small private helpers off
        # ImagePipe.Transform.Executor (`overlay/2` and
        # `boundary_source_dimensions/1`) — Executor is not exported from the
        # Transform boundary and is core-frozen, so a dialect's own resolve-loop
        # driver cannot call it; see the module docs in
        # lib/image_pipe/dialect/native/pipeline.ex and
        # lib/image_pipe/dialect/imgproxy/pipeline.ex, and the Task 14 report.
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
        # ImagePipe.Dialect.SharedConfig.validate_allow_origin/1 deliberately
        # duplicates ImagePipe.Request.Options.validate_allow_origin/1 (three
        # clauses, same messages) so both dialects validate `allow_origin` the
        # same way the framework does without depending on the Request
        # boundary (Options is framework-frozen). Ignored for the same reason
        # as the pairs above.
        #
        # ImagePipe.Dialect.Imgproxy and ImagePipe.Dialect.Native are each a
        # top-level dialect's Plug chain, and structurally mirror each other:
        # init/call, OPTIONS/method-not-allowed routing, send_with_span/1 +
        # request_metadata/1, negotiate/3's policy branch, build_and_pump/6,
        # materialize_for_delivery/2, pipeline_opts/4, send_not_modified/3, and
        # the transform-execute/encode/send telemetry spans. Neither may name
        # the other (a product dialect never depends on another product
        # dialect), so this cannot be shared by reference.
        #
        # ImagePipe.Dialect.Imgproxy.Pipeline and ImagePipe.Dialect.Native.Pipeline
        # mirror each other the same way one level down: follow/5,
        # condition_color/2, and build_ctx/1 implement the same resolve-loop
        # driver shape in both dialects' Pipeline modules, for the same
        # neither-dialect-may-depend-on-the-other reason.
        #
        # ImagePipe.Dialect.Imgproxy.detect_classes/1 mirrors
        # ImagePipe.Plan.detect_classes/1's exact return contract
        # (`:all | nonempty_list(String.t()) | nil`) over the dialect's own
        # `{:detect, {spec, weights}}` operation guides — the dialect never
        # builds a %Plan{}, so it cannot call the framework function directly,
        # and Plan is framework-frozen. See the doc on
        # ImagePipe.Dialect.Imgproxy.detect_classes/1.
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
        # ImagePipe.Dialect.Native and ImagePipe.Dialect.Imgproxy each also
        # deliberately mirror the framework's span helpers for the B3
        # dialect-emitted spans: encode_first_chunk/3 + first_chunk/1 +
        # encode_stop_metadata/2 off Request.DeliveryBuild, and
        # transform_stop_metadata/1 off Request.Processor. Both framework
        # originals are private helpers of framework-frozen Request-boundary
        # modules a dialect cannot depend on. Tracked with the rest under
        # hlindset/image_pipe#457.
        {ExDNA.Credo,
         excluded_macros: [:alias],
         ignore: [
           "lib/image_pipe/decode.ex",
           "lib/image_pipe/decode/source_format.ex",
           "lib/image_pipe/dialect/imgproxy.ex",
           "lib/image_pipe/dialect/imgproxy/pipeline.ex",
           "lib/image_pipe/dialect/native.ex",
           "lib/image_pipe/dialect/native/pipeline.ex",
           "lib/image_pipe/dialect/shared_config.ex",
           "lib/image_pipe/response/conditional.ex"
         ]}
      ]
    }
  ]
}
