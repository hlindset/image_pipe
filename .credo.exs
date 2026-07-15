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
        # The ImagePipe.Dialect.Imgproxy.* leaf request structs are near-verbatim
        # phase-1 copies of their ImagePipe.Parser.Imgproxy.* originals: the
        # inverted dialect owns its whole request chain and may not depend on the
        # Parser boundary, and the framework originals stay frozen while both arms
        # run side by side. Unlike the blessed mirrors above this duplication is
        # TRANSIENT — the originals are deleted in phase 2, at which point these
        # entries go with them (phase-1 dialect copy, retired in phase 2 per spec
        # 2026-07-15).
        {ExDNA.Credo,
         excluded_macros: [:alias],
         ignore: [
           "lib/image_pipe/decode.ex",
           "lib/image_pipe/decode/source_format.ex",
           "lib/image_pipe/dialect/imgproxy/crop_request.ex",
           "lib/image_pipe/dialect/imgproxy/effects.ex",
           "lib/image_pipe/dialect/imgproxy/format.ex",
           "lib/image_pipe/dialect/imgproxy/orientation.ex",
           "lib/image_pipe/dialect/imgproxy/pipeline_request.ex",
           "lib/image_pipe/dialect/native/pipeline.ex",
           "lib/image_pipe/response/conditional.ex"
         ]}
      ]
    }
  ]
}
