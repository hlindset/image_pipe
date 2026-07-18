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
        # note above). `ignore:` contains only core boundary mirrors that cannot
        # share code without changing the dependency graph: Decode mirrors
        # Request.Processor / Request.SourceFormat, SharedConfig mirrors
        # Request.Options, and Response.Conditional mirrors Request.HTTPCache.
        {ExDNA.Credo,
         excluded_macros: [:alias],
         ignore: [
           "lib/image_pipe/decode.ex",
           "lib/image_pipe/decode/source_format.ex",
           "lib/image_pipe/dialect/shared_config.ex",
           "lib/image_pipe/response/conditional.ex"
         ]}
      ]
    }
  ]
}
