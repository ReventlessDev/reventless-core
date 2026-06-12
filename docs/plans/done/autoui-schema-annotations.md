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

## Phase 3 — `@drillTarget` and `@collapsed` annotations ✅ DONE

**Depends on:** Phase 1 (extension property pipeline established).

**Goal.** Allow type authors to provide hints about hierarchical rendering of nested fields.

**Implementation.** Reuses the Phase 1 metadata pipeline:

1. `Reventless.StateAnnotations.stateAnnotationSpec` (`reventless/reventless-spec/src/components/StateAnnotations.res`) gained three fields: `drillTargets: array<(string, string)>` (`(fieldName, sliceName)` pairs), `drillTargetKeys: array<(string, string)>` (`(fieldName, keyPath)` pairs — only fields with an explicit `key` parameter), and `collapsed: array<string>`.
2. The PPX (`packages/reventless-ppx/src/ppx/StateAnnotations.ml`) recognises `@drillTarget(...)` and `@collapsed` on fields within `@schema type state` (`has_drill_target_field_attr`, `has_collapsed_field_attr`, `find_drill_target_attr`, `get_drill_target_args`), strips them via `strip_drill_collapsed_attrs` (wired into `ReventlessPpx.ml` after the existing strippers), and writes the collected names/pairs into the metadata record. `@drillTarget` accepts both the short string-literal form `@drillTarget("SliceName")` and the record form `@drillTarget({slice: "SliceName", key: "field1/field2"})`.
3. `SuryToJsonSchema.mergeAnnotations` (`reventless/reventless-core/src/components/Api/SuryToJsonSchema.res`) emits `"x-reventless-drillTarget": "SliceName"`, `"x-reventless-drillTargetKey": "field1/field2"` (only when supplied), and `"x-reventless-collapsed": true` on the matching field schemas.

**Tests.**
- PPX integration test (`packages/reventless-ppx/test/run.sh`, `DrillReadModel.res`) verifies `drillTargets`, `drillTargetKeys`, and `collapsed` keys appear in the compiled metadata for both the short and record forms, that the slice name and key path are preserved, and that the `@drillTarget`/`@collapsed` source annotations are stripped from the output.
- Unit tests (`reventless/reventless-core/tests/api/SuryToJsonSchemaTest.res`) cover the `x-reventless-drillTarget`, `x-reventless-drillTargetKey`, and `x-reventless-collapsed` extension properties and confirm `x-reventless-drillTargetKey` is absent when no key is supplied.

**Convention.** `@drillTarget("SliceName")` = navigate to the named slice/view instead of inline expansion (typically used on `array<...>` fields); `@drillTarget({slice: "SliceName", key: "field1/field2"})` = same, plus a key path identifying which sub-fields of each array element form the drill-down key; `@collapsed` = render the field as an inline summary instead of expanding (typically used on object fields).

---

## Phase 4 — Wire `deriveObjectSchema` into `Plugin_Structure` queryable defs ✅ DONE

**Status.** Completed 2026-04-28. The two-line swap landed at `Plugin_Structure.res:261` (read models) and `:280` (state-view slices). Verified via new unit + integration tests; full reventless-core suite (312 tests, 29 suites) and zero-warning build green.

**Depends on:** Phase 1 (encoder shipped in `SuryToJsonSchema.deriveObjectSchema`).

**Goal.** Make the JSON Schemas attached to `Platform_UIDefinitions.readModels[].schema` and `stateViewSlices[].schema` carry the `x-reventless-*` extension properties they're supposed to. Today they don't, because `Plugin_Structure.res` calls Sury's built-in `S.toJSONSchema` instead of `SuryToJsonSchema.deriveObjectSchema`.

### Root cause

The annotation pipeline established in Phase 1 has three end-to-end pieces — PPX → metadata → annotation-aware encoder — and they all work in isolation. The break is at the *consumer*: `reventless/reventless-core/src/components/Plugin/Plugin_Structure.res:261` (read models) and `:280` (state-view slices) bypass the annotation-aware encoder and call Sury's native `S.toJSONSchema`, which is metadata-blind. Result: the `Platform_UIDefinitions` payload ships JSON Schemas that look like `{type: "object", properties: {pluginName: {type: "string"}, …}}` — no `x-reventless-id`, no `x-reventless-subId`, no `x-reventless-index`. Verified end-to-end against `examples/online-shop/platform-in-memory` running locally on 2026-04-28: every read model returned by `Platform_UIDefinitions` had `has-annotations=False`.

The downstream cost is the entire `reventless-ui` Phase 6.5 capability path (server-side filter / sort / pagination). `AutoServerCapability.summarizeSchema` correctly returns `{hasFilter: false, hasSort: false}` for these schemas, so `AutoUI.generateFragments` emits the legacy zero-arg query and URL params (`?f.<field>=…` / `?sort=…&dir=…` / `?after=…`) route to client-side fallbacks regardless of whether the server-side SDL would accept them. The SDL itself is correctly shaped (introspection confirms `filter: Platform_DeploymentHistoryFilter`, `orderBy: Platform_DeploymentHistoryOrderBy`, `first/after/last/before`) — the gap is only in what the client *sees* through `Platform_UIDefinitions`.

### Implementation

Two-line change at the data-emit site:

1. **`reventless/reventless-core/src/components/Plugin/Plugin_Structure.res:261`** — read model schema. Replace
   ```rescript
   schema: (R.Spec.stateSchema->S.toJSONSchema->Obj.magic: JSON.t)->JSON.stringify,
   ```
   with
   ```rescript
   schema: R.Spec.stateSchema
     ->S.castToUnknown
     ->SuryToJsonSchema.deriveObjectSchema
     ->JSON.stringify,
   ```
2. **`reventless/reventless-core/src/components/Plugin/Plugin_Structure.res:280`** — state-view slice schema. Same swap on `SVS.Spec.stateSchema`.

The `Obj.magic` cast disappears because `deriveObjectSchema` returns `JSON.t` directly. The `castToUnknown` is required because `deriveObjectSchema: S.t<unknown> => JSON.t` and `stateSchema: S.t<state>` (already exercised this way in `Plugin_Structure.res:256/275` for `labelFieldsFromStateSchema`).

### Out of scope

- **Command schemas at `Plugin_Structure.res:124`.** Commands don't currently carry structural annotations (`@id`, `@subId`, etc. are state-side only — they describe *identity*, not command shape), so swapping the encoder there is a no-op for the auto-UI's capability path. Leave the command-schema call site on `S.toJSONSchema` until a future phase introduces command-side annotations and proves output-parity for unannotated commands.
- **Secondary `encodeQbl` MCP-server path** (`reventless/reventless-in-memory/src/Platform.res:1860–1882`). That serializes `queryableDef.schema` as already-stringified JSON — it just passes the result of `Plugin_Structure` through. Once the source is fixed, this path picks up the new shape automatically.
- **AWS adapter (`reventless-aws`).** This plan only changes `reventless-core`. The AWS resolver path consumes the same `queryableDef.schema` produced by `Plugin_Structure`, so the fix flows through transparently when an AWS deploy is rebuilt.

### Risks & sanity checks

- **Output parity for unannotated types.** `deriveObjectSchema` walks via `SchemaType.fromSuryObject`; `S.toJSONSchema` is Sury's native serializer. For state schemas with no `x-reventless-*` annotations the output should be structurally equivalent (both emit `{type: "object", properties: {…}, required: […]}`), but they're not byte-identical implementations. Add a parity test (see "Validation" below) before swapping to catch any structural regression — particularly for nested objects, arrays, and unions.
- **Schema-string consumers.** Anyone currently parsing the schema string with a strict JSON Schema validator that rejects unknown keywords would break. JSON Schema Draft 2020 explicitly reserves `x-` and unknown keywords are valid by default, but if a downstream tool was hand-rolled to be strict, it would need to be relaxed. Search the consumer side (UI, MCP server, any external tooling) for a strict-mode validator before merging.
- **Sury metadata not transferred when `castToUnknown` is wrong.** `castToUnknown` should preserve metadata bindings (it's a type-level cast). Phase 1's `SuryToJsonSchemaTest.res` already covers `getSpec` returning the spec from a cast schema; this fix relies on that invariant. If a regression surfaces, the symptom would be `deriveObjectSchema` emitting plain output with no `x-reventless-*` keys despite the source type being annotated — the same failure mode we're fixing.

### Validation

- **Unit ✅.** `reventless/reventless-core/tests/api/SuryToJsonSchemaTest.res` gained a `parity with S.toJSONSchema for unannotated objects` describe block: asserts the two encoders produce the same `properties` keyset and `required` array, and confirms `S.toJSONSchema` does *not* emit `x-reventless-*` keys even when metadata is set (so the integration test below can't false-positive on the legacy path).
- **Integration ✅.** `reventless/reventless-core/tests/plugin/PluginStructureTest.res` gained a `queryableDef.schema propagates x-reventless-* annotations` describe block backed by a new fixture `tests/plugin/StateViewSlice/PsAnnotatedView.res` (one `@id itemId`, one `@subId version`, one `@index("byOwner") ownerId`, plus an unannotated `name`). After `JSON.parseOrThrow`, the test asserts `x-reventless-id` on `itemId`, `x-reventless-subId` on `version`, `x-reventless-index = "byOwner"` on `ownerId`, no `x-reventless-*` on `name`, and no `x-reventless-id` on the unannotated `Orders` SVS for cross-checking. The pre-existing "produces three SVS entries" count was bumped to four.
- **Build ✅.** `pnpm exec rescript-legacy build` from `reventless-core` — clean, zero warnings.
- **Tests ✅.** `pnpm test` from `reventless/reventless-core` — 312 tests across 29 suites, all green (24 in `PluginStructureTest`, 18 in `SuryToJsonSchemaTest`).
- **Server-side wire smoke ✅.** Run 2026-04-29 against a downstream consumer example app (online-shop `platform-in-memory`) linked to local core (`pnpm link:on` overlay), restarted on `:4001`, probed directly via `POST /graphql { Platform_UIDefinitions { stateViewSlices { name schema } } }`. The Platform plugin's `DeploymentHistory` SVS schema now ships:

    | field          | `x-reventless-*` keys                              |
    |----------------|-----------------------------------------------------|
    | `environment`  | `compositeId: true`, `index: true`                  |
    | `platformName` | `compositeId: true`                                 |
    | `pluginName`   | `compositeId: true`                                 |
    | `sortKey`      | `subId: true`                                       |
    | `eventType`    | `summary: true`                                     |
    | `timestamp`    | `index: "byTime"`, `summary: true`                  |

    Same shape across the other annotated SVS entries. Confirms the PPX → metadata → `deriveObjectSchema` → `Plugin_Structure` → wire chain is end-to-end. Whatever query shape the auto-UI now generates is a function of this schema; emitting connection-style queries with `filter`/`orderBy`/`first`/`after` is no longer gated on changes in this repo.

- **End-to-end browser smoke ⚠️ deferred.** Could not run against published artifacts: `@reventlessdev/dev-app@0.2.0-alpha.2` and `@reventlessdev/reventless-ui@1.7.0-alpha.2` ship raw `.res.mjs` whose imports reference `rescript-relay/src/*.res.mjs` and `bs-css-emotion/src/CssJs.res.mjs` — the former ships only `.bs.js`, the latter is source-only. Runtime resolution fails before any GraphQL request leaves the browser. This is a packaging issue in those published artifacts, independent of this plan; the server-side wire smoke above is sufficient to confirm Phase 4 lands as designed. Re-run the browser smoke once a fixed dev-app is published.

  **2026-04-30 update.** Fixed in `reventless-ui/docs/plans/publish-bundled-artifacts.md` (uncommitted in that repo, ready for `lerna publish`): both packages are now JS-only — `dev-app` ships a vite-built `dist/`, `reventless-ui` ships a vite library bundle (`dist/index.mjs`, ~380 kB / 86 kB gzip), and neither tarball contains `.res.mjs`. The browser smoke remains deferred until alpha.3 is published *and* the unrelated `TypeError: Uuid.v4 is not a function` in `reventless-core/.../Message.res.mjs:44:15` is fixed (stale `uuid@3.4.0` in `reventless-core/node_modules/uuid` despite `^13.0.0` declared — `rm -rf node_modules/uuid && pnpm install` clears it).

  **2026-05-01 update — both blockers cleared.** UI side: alpha.0 of `@reventlessdev/reventless-playground` (renamed from `dev-app`), `@reventlessdev/reventless-ui`, and `@reventlessdev/reventless-routes` are published; lockfile synced in `52f0a1e2f`. Core side: the uuid resolution was already durably fixed for `reventless-core` by `87bf8cca3` (2026-04-23, direct dep), but a latent identical bug existed in `reventless-aws` (called `Uuid.v4()` without declaring uuid); fixed in `57a7153e1`. Browser smoke is unblocked end-to-end on this repo's behalf — runnable against fresh installs of the alpha.0 published artifacts whenever needed; nothing further is required from this plan.

### Cross-repo coordination

The fix is purely in `reventless-core`. No `reventless-ui` change is needed — the auto-UI is already correctly deciding capability from whatever schema it sees. the downstream consumer repo only needs to rebuild against the patched `reventless-core` (workspace-link via `pnpm-workspace.local.yaml`, or republish + reinstall) for the smoke to pass.

The corresponding tracking note in the UI plan (`reventless-ui/docs/plans/autoui-improvements-ui.md`, Phase 6.5 validation block) can be flipped from ❌ to ✅ once this lands and the browser smoke is re-run.
