# Content-aware cropping and detector integration review

Investigation: `image_plug-6z9.8`, under `image_plug-6z9`.

## Summary

Keep the detector extension point, concrete composite routing, and crop fallback
policy. The useful simplification is inside crop execution: share dimension
resolution and carry only the detector shape the executor actually produces.
The user authorized investigation followed by fixes. Implementation is tracked
in `image_plug-zde`; the separate warmup error finding is `image_plug-44j`.

## Responsibilities and boundaries

| Owner | Responsibility and real consumers |
| --- | --- |
| `Plan.Request.assemble_detection/1` | Canonical class order and sparse positive weights from validated URL/native input. Consumed by processing, identity, and the executor. Already consolidated by `image_plug-9o8`. |
| `Processing.explicit_detector_classes/1`, `check_detector/2` | Union explicit classes across groups; reject required but unavailable detection before source/cache work. Face-assisted attention is intentionally optional. |
| `Execution.detector_identity/2` | Add face assistance to the explicit class union; ask the transform facade for model identity. Both cache key and ETag consume it. |
| `Transform.resolve_detector/1`, `Executor.execute/3` | Resolve host configuration (`:default`, module, or nil) to a module or nil in transform state. |
| `Detector`, `Detector.Composite` | Host callback contract and ordered child routing. The composite merges successful children, errors when every routed child fails, and limits identity/availability to routed children. |
| `Detector.ImageVision.Face`, `Objects` | Optional dependency boundary, model identity, exception translation, absolute region boxes, and object label normalization/filtering. Static vocabularies work without loading models. |
| `Operation.Crop`, `Focal` | Validate external detector return structure, reject out-of-image boxes, compute the weighted centroid, blend face assistance with attention, and fall back to attention. Smart/detect crops require materialization. |
| `Detector.Warmup` | Host-started transient worker; model loading in `handle_continue`, bounded retry, normal exit, and no automatic library startup. |

## Safe To Patch Now

### Share crop dimensions (`image_plug-zde`)

Before this change, `Crop.resolved_rect/3`, `smart_crop/3`, and
`attention_point/2` repeated dimension resolution and aspect correction already
owned by `resolved_box_dims/3`. Their `crop_dimensions/3` helper only copied two
fields into an always-success tagged map. Reuse the existing concrete resolver
and delete that wrapper. No new abstraction or callback is needed.

The clamp is equivalent for real inputs: `Geometry.resolve_dimension/2` bounds
each dimension; non-nil aspect correction also bounds its result. Keep rounding,
coordinate placement, centroid weighting, materialization, and fallback rules.

### Narrow detector state (`image_plug-zde`)

`Processing.Config` accepts only module atoms, `:default`, or nil, and
`Executor.execute/3` calls `Transform.resolve_detector/1` before executing groups.
Only `crop_operation_test.exs` constructed `{module, opts}` in state. Remove that
tuple form and its normalization helper; pass state directly to the private
detection helper. The test fake now stores its configured result in the calling
test process and returns its module. These synchronous operation tests retain
their real host-boundary malformed-result and fallback assertions.

`State.detector_required` had no producer or consumer beyond its declaration.
Delete the field and its documentation/type entry. The public configuration and
`Processing.check_detector/2` strict gate remain intact.

These changes reduce production code and internal surface area. The touched
telemetry tests use private per-test event prefixes. No cache identity, event,
public option, buffering, or model behavior changes are intended.

## Needs Discussion / Separate Validation

### Warmup failures are swallowed (`image_plug-44j`)

Both bundled adapters discard the result of their inference helper during
`warmup/1` and return `:ok`. The helpers rescue dependency failures into tagged
errors, so the worker never sees those failures and cannot retry them. Propagate
the error while mapping successful inference to `:ok`. This is a separate
behavioral fix requiring the optional ML lane and a failed-initialization
regression; it is not included in the crop cleanup.

## Retained Design

- Keep explicit-class preflight separate from identity's inclusion of face
  assistance: they implement different documented policies, not duplicate
  normalization.
- Keep `Composite`'s struct API: custom detector modules can delegate to a
  configured child list; existing host-contract fixtures exercise this path.
- Keep optional warmup callback probes and adapter dependency rescues. These
  cross real host/dependency boundaries.
- Keep structural detector-result validation and Focal's bounds filtering.
  External region data is not trusted internal planner output.
- Keep the transient warmup worker and serial child routing. There is no
  demonstrated simplification that justifies changing startup/retry ownership
  or inference scheduling.
- Leave new detection effects and object positioning to `image_plug-tvr`.

## Test Impact and Verification

Retain crop placement properties, malformed host-result fallback, face blend,
class routing, and request-level pixel/identity/strict-preflight tests. Replace
the tuple injection mechanism without deleting those behavioral assertions.
The focused suite passed before and after the change: 73 tests/properties,
four optional ML tests excluded.

Focused command:

```sh
mise exec -- mix test test/image_pipe/transform/crop_operation_test.exs test/image_pipe/transform/focal_test.exs test/image_pipe/transform/detector_test.exs test/image_pipe/transform/detector test/image_pipe/api/object_crop_wire_test.exs test/image_pipe/api/crop_ratio_trim_wire_test.exs
```

Full validation passed: `mise run precommit` (format, warnings-as-errors
compilation, Credo, Dialyzer, duplication check, and 2,529 tests/properties;
four optional ML tests excluded). No performance claim is made;
buffering, streaming, inference scheduling, and admission are unchanged.
