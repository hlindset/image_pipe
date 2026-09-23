# Automatic quality and byte-budget search

Investigation: `image_plug-6z9.10`. Cleanup: `image_plug-6z9.10.1`.

## Ownership and flow

1. `API.OutputOptions`, `Plan.Builder.OutputOptions`, and `Processing.Config`
   validate URL, builder, and host inputs respectively. `Plan.Output.QualitySearch`
   combines validated target/bracket fields with host defaults. A size objective
   still needs an explicit target from one of those sources.
2. `Output.RequestPolicy` checks effective per-format brackets.
   `Output.Policy.resolve_search/2` selects the concrete format bracket and crop
   offsets. Plan and resolved structs describe different stages: format maps and
   sparse URL overrides disappear when a format is selected.
3. `Output.Encoder` finalizes pixels, selects full-frame or crop scoring, and
   invokes `EncodeSearch.run/3`. Lossless output and resolution-cap skips use the
   existing one-encode path. Native JPEG XL search is absent in the current tree
   following the separate output-support removal.
4. `EncodeSearch.run/3` creates native encode/score closures; `search/3` runs the
   objective, optional confirmation, byte cap, and result assembly. Its context
   owns encoded buffers, score/confirmation memos, iteration counts, and the
   per-quality telemetry provenance. The winning buffer is returned directly.
5. `Output.Metric` adapters own native reference/score calls and scoring polarity.
   `Plan.Output.QualitySearch.Metric` owns validation ranges and mathematical
   direction. `CropScore` owns tile selection and p10 aggregation;
   `ContentClassifier` selects the calibrated content-class offset. Native
   failures retain their error or documented conservative-class fallback.

## Safe To Patch Now

Implemented together in `image_plug-6z9.10.1`:

- Remove runtime `target_range/0` callbacks and delegates. All production target
  validation reads the Plan metric facts; runtime consumers use only direction,
  reference, score, and telemetry leg name. Delete the migration parity assertion
  and retain boundary range tests and real metric scoring coverage.
- Remove target range revalidation in `QualitySearch.resolve_target/3`. Both
  possible target producers are validated: request fields by URL/parser or
  builder, host maps by configuration. Retain missing-target handling because a
  valid size configuration can omit its target. Boundary tests now exercise
  negative/too-large metric targets and nonpositive/noninteger byte targets.
- Remove the unused objective-score tuple member; `do_search/4` discarded it.
- Remove the full-frame winner-rescore fallback. `do_encode/3` is the only writer
  of `encode_memo` and invokes `maybe_score/3` before returning; `score_fun` never
  changes. Thus every returned encoded candidate has its objective score when a
  scoring closure exists. Keep confirmation of a cap-relocated winner: its
  authoritative confirmation score really can be absent.
- Fetch chosen-probe provenance directly. The same `do_encode/3` operation
  inserts both the buffer and its phase/index; result assembly already requires
  the winning buffer. A missing provenance map is not a real producer state.
- Remove a test constructing incomplete internal search structs merely to test
  Elixir's required-key enforcement.

These changes narrow internal contracts and remove repeated work or unreachable
branches. They do not change candidate order, scoring calls, delivered bytes,
iteration limits, telemetry names/fields, thresholds, or corpus policy.

## Retain

- **Two search primitives.** Highest-fitting size search and perceptual band
  search optimize different outcomes. Their shared encode/score memoization is
  already centralized; a generic strategy framework would obscure branching.
- **Concrete objective structs.** Shared bracket fields are small and explicit.
  Size lacks metric tolerance, while resolved SSIMULACRA2 carries crop offsets.
  Merging these into a broad options map would allow meaningless combinations.
- **Confirmation/bump support.** It is absent from production crop scoring but
  used by `autoquality.bench` at the crop+confirm baselines. Keep its bounded
  linear bump and cap-relocated-winner confirmation so benchmarks remain useful.
- **Boundary encode after the iteration cap.** A chosen fallback must have real
  bytes; the algorithm can force that final encode. Keep the measured result
  and best-effort floor/ceiling outcomes rather than pretending unprobed values
  fit. Real codecs can be locally nonmonotonic; this is a bounded heuristic.
- **Metric errors and telemetry.** Native decoding/scoring may fail. The tagged
  score throw crosses nested telemetry spans and is translated by `run/3`.
  Replacing that protocol would change observable exception/stop events and
  requires a separate behavioral proposal, not a mechanical cleanup.
- **Classifier and crop geometry.** Their thresholds, 16×512px sample, offsets,
  and crossover form a calibrated policy. Keep the conservative graphic
  fallback and existing realization boundaries.

## Related decisions

No new algorithm or default change is recommended from this code audit.
`image_plug-ciw` already owns the WebP ceiling experiment and `image_plug-w9g`
owns the crop tile-count/size sweep. Both need corpus accuracy, bytes, and runtime
evidence before changing production policy; neither blocks this cleanup. The
benchmark confirmation support is retained for those comparisons. Search
identity and encoder-stage ownership were reviewed in `6z9.9`; no duplicate
implementation issue is created.

## Validation

The expanded boundary tests plus search examples, properties, and telemetry
passed before the cleanup: 91 tests and 7 properties. After cleanup, 429 tests
and 13 properties passed across output/search, Plan, benchmark support,
builder/host/URL boundaries, quality wire behavior, and Logger/trace capture.

Full `mise run precommit` passed: formatting, warnings-as-errors compilation,
Credo, Dialyzer, duplication analysis, and 2,528 tests/properties, with 5 optional
integration exclusions.
