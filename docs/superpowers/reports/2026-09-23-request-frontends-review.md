# Request frontends and canonical plans review

Review date: 2026-09-23. Investigation: `image_plug-6z9.1`.
Scope: URL lexing/parsing/serialization, native plan builders, canonical
request construction, and shared semantic validation.

## Responsibility and caller audit

| Owner | Producers and consumers | Conclusion |
| --- | --- | --- |
| `API.Path` | `API.parse/2` calls `split_signature/1` before verification and `extract/1` afterward. `API.Errors` uses `diagnostic_path/1`; `API.URL` uses `max_option_segments/0`. | Keep all four entry points. Raw signing bytes, diagnostic spans, secret masking, and bounded lexing have separate contracts. |
| `API.Parser` | Consumes lexed paths; `API.Presets` also calls `parse_preset/1` and `message_for/1`. | Keep preset parsing and diagnostic translation in the URL layer. Preset fragments cannot be validated as complete requests before composition. |
| `Plan.Builder.Options` | `Plan.new/1`, `group/2`, and `output/2` consume public keyword options. Nested effect and output parsers call `validate/2`. | Keep shape, duplicate-key, and field validation at this external input boundary. |
| `Plan.Builder.Values` and `Builder.OutputOptions` | NimbleOptions invokes their custom callbacks, including `cast/2`, `encoder/2`, `autoquality/1`, and `metric_target/2`. | These public functions have indirect callers; ordinary call-site searches alone cannot establish that they are unused. |
| `Plan.Request` | `Parser` and `Plan` call `errors/3` and then `build/3`. | Keep one semantic validator and canonical constructor. Preserve explicit choices until applicability validation has run. |
| `Request.Group`, `Request.Output`, `Request.Issue` | Executor/geometry, decode/output policy, and public validation results consume these types. | Keep these concrete boundary exports. Builder implementation modules remain private to the Plan boundary. |
| `API.Serializer` | `API.URL` passes canonical requests to `segments/1`; `SerializedValue` supplies decimal and scalar formatting. | Keep serialization downstream of canonical construction. |

`ImagePipe.new/1` has two supported inputs: request-option keywords and a
reusable `Config` struct. The builder tests exercise the first; configured
builder tests exercise the second. `Plan.new/1` itself accepts only keywords.
There is no unused internal map/keyword/struct constructor family to delete.

## Completed simplifications

- `image_plug-j64`: removed unused option-table stage, default, prerequisite,
  and identity metadata, preserving examples used by behavioral tests.
- `image_plug-9o8`: moved detection selection sorting and sparse weight
  normalization into private canonical request construction.
- `image_plug-p4o`: made each option declaration own its canonical name;
  the parser derives forward and reverse maps. Presets are expanded before
  canonical translation and have no canonical request field.
- `image_plug-9gj`: placed typed encoder constraints on the existing codec
  option modules. Native builders and host configuration use their schemas;
  the URL layer derives its value parsers while owning URL spellings and
  boolean syntax. Sparse host structs still omit nil fields, explicit false
  remains meaningful, and malformed input is rejected at each boundary.
- `image_plug-lc7`: required a nonempty diagnostics list in the malformed
  parser-input regression. Substituting an empty list fails the assertion.

## Retained design

`Path.split_signature/1` and `extract/1` inspect the same raw path at different
security stages. Combining them would risk validating or decoding before
signature verification. The path tests cover exact spans, malformed escapes,
source decoding once, mount prefixes, and masked signatures/encrypted tokens.

The serializer's single-group and multiple-group paths preserve group
boundaries. A group reduced to identity values needs a `dpr=1` segment when
it participates in a sequence. Its explicit profile handling and decimal
expansion preserve URL syntax and round trips. These are meaningful cases,
not fallback behavior for impossible internal callers.

Native keyword validation and URL value parsing accept different public
representations. Their numeric overflow handling protects real caller input.
Semantic requirements and identity normalization remain shared; merging
the two input grammars would obscure their contracts.

Moving the remaining OptionSpec value parsers into another module would
change organization without reducing responsibilities. Retain them. Likewise,
retain the bounded linear option lookup: no request-latency evidence currently
justifies a separate lookup optimization. No buffering, streaming, geometry,
resource-ownership, or telemetry change is proposed by this review.

## Verification evidence

Relevant coverage includes `builder_test`, `configured_builder_test`,
`builder_wire_test`, and the API path, parser, diagnostic, preset composition,
serializer, canonical property, identity, config, and quality wire suites.
Encoder changes also exercise `output/encoder_options_encode_test` and the
architecture boundary tests. Beads contains the command results and commit
references for each implementation task.

The remaining scope has a keep-as-is conclusion; this review does not imply
that the other fifteen subsystem investigations are complete.
