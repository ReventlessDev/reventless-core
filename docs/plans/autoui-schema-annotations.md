# Plan: Propagate Structural Annotations to JSON Schema

**Goal.** Propagate structural PPX annotations (`@id`, `@subId`, `@compositeId`, `@index`) from ReScript state type definitions into the generated JSON Schema as `x-reventless-*` extension properties. This enables downstream UI consumers to make intelligent decisions about field visibility, ordering, and entity linking without name-based heuristics.

---

## Phase 1 — Propagate existing structural annotations to JSON Schema ✅ DONE

**No new annotations.** Ships existing `@id`, `@subId`, `@compositeId`, `@index` data through the schema pipeline that already exists.

**Implementation.** The reventless-ppx and `SuryToJsonSchema` together carry the metadata end-to-end:

1. New runtime module `Reventless.StateAnnotations` (`reventless/reventless-spec/src/components/StateAnnotations.res`) defines a sury `Metadata.Id` keyed `~namespace="reventless" ~name="stateAnnotations"` and a `stateAnnotationSpec` record with `ids`, `compositeIds`, `subIds`, `compositeSubIds`, and `indexes: array<(string, string)>` (`(fieldName, indexName)` — empty index name for unnamed `@index`).
2. The PPX (`packages/reventless-ppx/src/ppx/StateAnnotations.ml::generate_state_annotations`) collects the annotations from each `@schema type state` field and emits a shadowing `let stateSchema = stateSchema->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, {...})` binding directly after sury-ppx generates `stateSchema`. Wired in `ReventlessPpx.ml` for both ReadModel and StateViewSlice files.
3. `SuryToJsonSchema.deriveObjectSchema` (`reventless/reventless-core/src/components/Api/SuryToJsonSchema.res`) reads the metadata via `Reventless.StateAnnotations.getSpec` and merges `x-reventless-id`, `x-reventless-compositeId`, `x-reventless-subId`, `x-reventless-compositeSubId`, and `x-reventless-index` into each field's JSON Schema object.

**Tests.**
- PPX integration tests (`packages/reventless-ppx/test/run.sh`) verify that `stateAnnotationsId` and the per-annotation array keys (`ids`, `compositeIds`, `subIds`, `compositeSubIds`, `indexes`) appear in the compiled `.res.mjs` for read models with each annotation, and that the metadata binding is *absent* when no annotations are present.
- Unit tests (`reventless/reventless-core/tests/api/SuryToJsonSchemaTest.res`) verify that `deriveObjectSchema` emits `x-reventless-*` extension properties on the right fields and only on the right fields.

**Resulting JSON Schema shape.**
```json
{
  "properties": {
    "pluginName":  { "type": "string", "x-reventless-id": true },
    "environment": { "type": "string", "x-reventless-compositeId": true },
    "sortKey":     { "type": "string", "x-reventless-subId": true },
    "ownerId":     { "type": "string", "x-reventless-index": "byOwner" },
    "category":    { "type": "string", "x-reventless-index": true }
  }
}
```

---

## Phase 2 — New `@hidden` and `@summary` annotations ✅ DONE

**Depends on:** Phase 1 (extension property pipeline established).

**Goal.** Allow type authors to explicitly control downstream UI field visibility beyond what structural annotations convey.

**Implementation.** Reuses the Phase 1 metadata pipeline:

1. `Reventless.StateAnnotations.stateAnnotationSpec` (`reventless/reventless-spec/src/components/StateAnnotations.res`) gained two fields: `hidden: array<string>` and `summary: array<string>`.
2. The PPX (`packages/reventless-ppx/src/ppx/StateAnnotations.ml`) recognises `@hidden` and `@summary` on fields within `@schema type state` (`has_hidden_field_attr`, `has_summary_field_attr`), strips them via `strip_visibility_attrs` (wired into `ReventlessPpx.ml` after the existing strippers), and validates that no field carries both (`validate_visibility_annotations` raises `@hidden and @summary cannot both appear on the same field 'X'`). The collected names are written into the metadata record.
3. `SuryToJsonSchema.mergeAnnotations` (`reventless/reventless-core/src/components/Api/SuryToJsonSchema.res`) emits `"x-reventless-hidden": true` and `"x-reventless-summary": true` on the matching field schemas.

**Tests.**
- PPX integration test (`packages/reventless-ppx/test/run.sh`, `VisibilityReadModel.res`) verifies `hidden: ["deploymentId"]` and `summary: ["pluginName"]` appear in the compiled metadata and that the `@hidden`/`@summary` source annotations are stripped from the output. A negative test (`HiddenSummaryConflictReadModel.res`) verifies the conflict error is raised.
- Unit tests (`reventless/reventless-core/tests/api/SuryToJsonSchemaTest.res`) cover the `x-reventless-hidden` and `x-reventless-summary` extension properties and confirm they are absent from unannotated sibling fields.

**Convention.** `@hidden` = field should not appear in summary/list views; `@summary` = field should always appear in summary/list views. The two are mutually exclusive on a single field.

---

## Phase 3 — `@drillTarget` and `@collapsed` annotations

**Depends on:** Phase 1.

**Goal.** Allow type authors to provide hints about hierarchical rendering of nested fields.

**Concrete steps.**
1. Add `@drillTarget("SliceName")` annotation. When found on an array field, emit `"x-reventless-drillTarget": "SliceName"`. Support optional key parameter via `@drillTarget("SliceName", key="field1/field2")` → `"x-reventless-drillTargetKey": "field1/field2"`.
2. Add `@collapsed` annotation. When found on an object field, emit `"x-reventless-collapsed": true`.
3. Document: `@drillTarget` = navigate to another view instead of inline expansion; `@collapsed` = suppress expansion, show inline summary.

**Validation.**
- `@drillTarget("ResourceInventory") components: array<componentEntry>` produces the expected JSON Schema extensions.
- `@collapsed primaryResource: primaryResource` produces `"x-reventless-collapsed": true`.
