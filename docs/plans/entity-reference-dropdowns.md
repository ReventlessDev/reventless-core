# Plan: Entity Reference Dropdowns — Core Backend

Implements the backend portion of the design in [reventless-ui/docs/analysis/auto-ui-entity-reference-dropdowns.md](../../../reventless-ui/docs/analysis/auto-ui-entity-reference-dropdowns.md).

Pairs with the UI-side work tracked in [reventless-ui/docs/plans/entity-reference-dropdowns-ui.md](../../../reventless-ui/docs/plans/entity-reference-dropdowns-ui.md).

**Goal.** Enable AutoUI command forms to render reference fields (e.g. `customerId`, `productIds`) as dropdowns backed by GraphQL queries, with a searchable combobox variant for large datasets. The UI can ship Phase A heuristically without any backend change; this plan covers the backend additions that let the UI scale to entities with thousands of rows, plus one SDL cleanup that the analysis surfaced as correctness-motivated.

Phases are ordered for ship-independence — each lands and is validated on its own.

---

## Phase 1 — Remove `totalCount` from Connection SDL ✅ done

**Context.** The `totalCount: Int` field on every `${Entity}Connection` is a footgun: populated in-memory, returns `null` in every AWS-backed deployment. Clients that code against it on the dev platform silently misbehave in production. See [auto-ui-entity-reference-dropdowns.md §B.8](../../../reventless-ui/docs/analysis/auto-ui-entity-reference-dropdowns.md#b8--core-cleanup-remove-totalcount-from-the-connection-sdl) for the full rationale.

**Goal.** Drop the field from the schema entirely so no consumer can depend on it, removing the in-memory / AWS divergence at the source.

**Files to change.**
- [GraphQL_FragmentGenerator.res](../../reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res) — remove `totalCount: Int` from the connection type emitted by `deriveConnectionTypes` at line 122.
- [QueryDbResolvers_GraphQL.res](../../reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res) — drop `"totalCount": items->Array.length` (line 253) and `"totalCount": 0` (line 224) from the connection payloads.
- [Platform.res](../../reventless/reventless-in-memory/src/Platform.res) — drop `("totalCount", JSON.Encode.int(items->Array.length))` from `connectionResponse` at line 977.
- [GraphQL_SchemaInspectorTest.res](../../reventless/reventless-in-memory/tests/adapter/GraphQL_SchemaInspectorTest.res) — remove the `totalCount: Int` assertion at line 290.

**Concrete steps.**
1. Remove `totalCount: Int` from the SDL string literal in `deriveConnectionTypes`.
2. Drop the `totalCount` keys from both in-memory connection-response builders.
3. Update the inspector test to assert the new shape (`edges`, `pageInfo` only).
4. Run the full test suite; any cross-repo consumer that references `totalCount` in a GraphQL query will now fail the schema-validation step — verify this is limited to internal fixtures and test code.
5. Grep for `totalCount` across `reventless-core`, `reventless-in-memory`, `reventless-aws`, `reventless-ui`, and the example plugins; remove stale references.

**Validation.**
- `npm run test` passes in `reventless-core` and `reventless-in-memory`.
- `grep -r totalCount reventless` returns zero matches outside of this plan document and its analysis counterpart.
- In-memory reventless-playground boots; Relay list queries return `edges` + `pageInfo` with no schema errors.

**Commit message.**
`feat!: remove totalCount from Connection SDL — field was unreliable in production (AWS never populated it)`

---

## Phase 2 — Composite `@displayName` annotation and projected `displayName` column ✅ core implementation landed

**Pairs with UI Phase A.2.** Additive; no UI-visible effect on its own.

**Implementation note.** Plan said "inject a synthetic `displayName: string` field" — landed as `displayName?: string` (optional). A mandatory field would force every projection body's `Create`/`Set` record literal to provide `displayName: "…"` as a placeholder; optional field avoids that migration. Consequence: GraphQL SDL emits `displayName: String` (nullable) instead of the plan's aspirational `String!`. The projection runtime overlay guarantees the field is always populated in practice.

**Also note.** The ppx-injected field must use `Location.none` for the label-declaration / type / attribute locations. When all four locations are equal to a single source `~loc`, the ReScript type-checker refuses to honour the `@res.optional` attribute and treats the field as mandatory — even though sury sees it as optional and the compiled `.res.mjs` is correct. `Location.none` ("ghost" location) is the idiomatic marker for synthesised AST nodes and works around this.

**Deferred for follow-up** (not blocking Phase 3/4 progress):
- Explicit error on `@displayName` coexistence with `@id` / `@compositeId` on the same field.
- Explicit error on `@displayName` on a field that already carries `@s.matches(...)`.
- Ppx snapshot / grep-based tests under `packages/reventless-ppx/test/`.
- End-to-end validation that a seeded customer's `displayName` equals the composed label after projection.

**Goal.** Add a field-level `@displayName` annotation that marks one *or more* fields as the human-readable label. Multiple annotations combine in declaration order with a separator (default `" "`). When any annotation is present, the ppx injects a synthetic `displayName: string` field into the state record and the projection runtime writes the composed value on every state mutation. Downstream phases target this one column uniformly.

**Why composite by default.** Real entities rarely have a single good label field — `firstName + lastName`, `city + street`, `sku + name`. A one-field rule forces authors to either accept suboptimal labels or project a synthetic column by hand. Baking composition into ppx + projection collapses this and gives Phases 3–4 a single target to search and index.

**Surface.**
```rescript
// Single field — unchanged ergonomics
@schema type state = { id: string, @displayName email: string }
// → displayName = email

// Composite, default " " separator
@schema type state = {
  id: string,
  @displayName firstName: string,
  @displayName lastName: string,
}
// → displayName = `${firstName} ${lastName}`  ("Ada Lovelace")

// Explicit separator (attach to any annotation; last wins)
@schema type state = {
  id: string,
  @displayName city: string,
  @displayName(", ") street: string,
}
// → displayName = `${city}, ${street}`
```

**Files to change.**
- New: `reventless/reventless-spec/src/components/DisplayName.res` — exports `displayNameSpec = {fields: array<string>, separator: string}`, `displayNameId: S.Metadata.Id.t<displayNameSpec>`, `getSpec: S.t<unknown> => option<displayNameSpec>`, and `computeLabel: (displayNameSpec, dict<string>) => string` (skips absent/empty parts, never emits leading/trailing/doubled separators).
- [reventless-spec/src/ReventlessSpec.res](../../reventless/reventless-spec/src/ReventlessSpec.res) — re-export.
- New: `packages/reventless-ppx/src/ppx/DisplayNameInference.ml` — new pass. For each `@displayName` attribute in `ld.pld_attributes` (field-declaration position, same slot as `@partitionTag`/`@dcbTag`), collect the field name, declaration-order index, and optional separator payload. Assemble a `displayNameSpec`, attach it via `S.Metadata.set(displayNameId, ...)` on the state schema, and inject a synthetic `displayName: string` field into the record type itself. Because the field is in the sury schema, GraphQL SDL emission, serialization, and storage all pick it up for free.
- [reventless-ppx/src/ppx/ReventlessPpx.ml](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml) — wire the new pass before the sury-ppx `@schema` transform so the injected record field is visible to sury's codegen.
- Projection runtime ([Projection.res](../../reventless/reventless-spec/src/components/Projection.res) and its functor in `reventless/reventless-core`) — when the target state schema carries `DisplayName` metadata, intercept `Set` / `Update` / `UpdateWithDefault` and run `computeLabel` against the about-to-be-written state, overwriting any caller-supplied `displayName`. One interception point covers every read model and state-view slice; plugin authors never compute it manually.

**Concrete steps.**
1. Build `DisplayName.res` and `computeLabel`. `computeLabel` reads each key from a state dict, drops `None`/empty strings, joins the rest with `spec.separator`.
2. Add the ppx pass. Cover: single annotation, composite with default separator, composite with explicit separator, composite over `option<string>` fields. Reject: non-string field types (clear error: `@displayName only supports string and option<string> fields`), annotation on `id`, annotation on a field that already carries another `@s.matches(...)` (unsafe to wrap — the field would need both; punt until a concrete case appears).
3. Ppx snapshot tests for every case in step 2 plus coexistence with `@dcbTag` / `@ref` / `@partitionTag` on *other* fields in the same record.
4. Wire the projection interception. The runtime path is "compute once per write, before storage" — not per-query. Unit test: projection against a composite-annotated target produces state records with `displayName` populated.
5. Rebuild and publish the ppx binary via the existing ppx-binary-management flow.

**Validation.**
- Ppx snapshot tests pass.
- Example plugin: `Customers` read model declares `@displayName firstName` + `@displayName lastName`. A seeded customer's `displayName` equals `"Ada Lovelace"` after projection.
- Plugins with no annotation compile and run unchanged — no synthetic field, no projection-layer overhead.
- GraphQL introspection against a composite-annotated entity shows `displayName: String!` without any change to the SDL emitter.

**Commit message.**
`feat: add composite @displayName annotation with projected displayName column`

---

## Phase 3 — Surface `labelField` on `Platform_UIReadSideDef` ✅ done

**Pairs with UI Phase A.3.** Depends on Phase 2.

**Implementation notes.**
- Source ladder lives in `Plugin_Structure.res` as `labelFieldsFromStateSchema` and is applied to both `readModelDefs` and `stateViewDefs`.
- The first-non-`id` fallback walks sury's `Object({items})` (declaration-ordered) rather than `properties` (dict) so the result is deterministic across compiles.
- When `DisplayName.getSpec` is present, `searchableFields` lists the *raw* underlying fields from `spec.fields` so clients with substring indexes can target them directly; otherwise it mirrors `labelField` (single element).
- `Logger.warn` fires once per queryable that falls back to `"id"` — helps surface missing annotations without breaking the build.
- Only the in-memory platform currently emits `Platform_UIDefinitions`; reventless-aws has no corresponding resolver (verified via `grep Platform_UIReadSideDef reventless/reventless-aws/src`), so no AWS work is needed until that query is mirrored there.

**Goal.** Expose the display-label field name (annotated or fallback-inferred) on the GraphQL schema so the UI can render entity labels without shipping its own fallback logic.

**Files to change.**
- [Plugin.res (spec)](../../reventless/reventless-spec/src/components/Plugin.res) — add `labelField: string` and `searchableFields: array<string>` to `queryableDef`.
- [Plugin_Structure.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res) — populate the new fields during read-model / stateViewSlice extraction. Source ladder: if `DisplayName.getSpec(stateSchema)->Option.isSome` → `labelField = "displayName"` (the projected column from Phase 2); else fallback to first non-`id` string property; final fallback `"id"` (log a warning). `searchableFields` mirrors `labelField` when composite is present and lists the *raw* underlying fields from `spec.fields` so clients with substring indexes can target them directly.
- [Platform.res (in-memory)](../../reventless/reventless-in-memory/src/Platform.res) — extend the SDL at line 1159 (and its copy at line 1740):
  ```graphql
  type Platform_UIReadSideDef {
    name: String!
    queryField: String!
    schema: String!
    consumedEventTypes: [String!]!
    linkedWriteSide: [String!]!
    labelField: String!            # new
    searchableFields: [String!]!   # new
  }
  ```
  Extend the encoder at `encodeQueryableDef` (lines 1176-1184) to emit the new fields.
- Any AWS platform resolver that mirrors the platform UI defs query — audit `reventless-aws/src` and extend analogously.

**Concrete steps.**
1. Extend the record types in `Plugin.res`.
2. Update `Plugin_Structure.make` to populate both fields for every `readModel` and `stateViewSlice`.
3. Emit a warning (via the existing logger) when the fallback is used — helps surface missing annotations without failing the build.
4. Update the SDL strings and encoder in both platforms.
5. Extend `PluginStructureTest.res` with cases asserting: composite annotation → `labelField = "displayName"`, missing annotation falls back to first non-`id` string, id-only state falls back to `"id"` with a warning.

**Validation.**
- `PluginStructureTest.res` tests pass.
- Dev-app GraphQL introspection shows the new fields on `Platform_UIReadSideDef`.
- Querying `Platform_UIDefinitions` for the online-shop example returns `labelField` values: `"name"` for Categories/Products (first string prop), `"email"` for Customers (if annotated), etc.

**Commit message.**
`feat: surface labelField and searchableFields on Platform_UIReadSideDef`

---

## Phase 4 — `filter` argument on Connection queries ✅ done

**Pairs with UI Phase B.4.** Depends on Phases 2 and 3.

**Implementation notes.**
- The pre-existing `${ReturnType}Filter` generated for the `{singleFieldName}Items` (sort-key) query conflicted with the new connection-level filter name. Renamed the items filter to `${ReturnType}ItemsFilter`; the new connection filter owns the plain `${ReturnType}Filter`. Breaking change for any client that queries the items-query filter by name — but intentionally chosen so the connection filter gets the canonical name on the top-level list query, which is the predominant list shape.
- `labelField` is threaded into the resolver via the existing `Plugin_Helpers.queryFieldNamesRegistry` rather than a new hook. Both `Plugin_Builder` and `Dcb_Builder` now call `Plugin_Structure.labelFieldsFromStateSchema` when populating the registry, so the resolver closes over the correct label column at construction time.
- `search` is case-insensitive substring on the in-memory adapter (`String.toLowerCase`/`String.includes`); DynamoDB's `contains` is **case-sensitive** (FilterExpression has no `tolower`). The SDL documents `search` as case-insensitive — the in-memory dev experience matches, the AWS prod path degrades to case-sensitive. A truly case-insensitive AWS path requires either a projected lowercased label column or external full-text search (deferred to Phase 6.1).
- `ids` uses DynamoDB `FilterExpression: #id IN (:id0, :id1, …)` (scan + post-filter) on the AWS path. BatchGetItem optimisation deferred — open question 1 below.
- The connection resolver does not yet implement cursor-based `first`/`after` slicing; filter is still applied pre-return. Pagination remains a follow-up — out of scope for this phase because the list resolver didn't paginate before Phase 4 either.

**Goal.** Extend every per-entity Connection query with a `filter: ${ReturnType}Filter` argument. The UI's combobox (search mode) submits `filter: {search: "..."}` to do server-side substring matching on the label field. Completes the Phase B feature from the analysis.

**Files to change.**
- [GraphQL_FragmentGenerator.res](../../reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res) — extend `deriveConnectionQueryField` at lines 158-162 to include `filter: ${returnType}Filter` (nullable). Add a new helper `deriveConnectionFilterType` producing:
  ```graphql
  input ${ReturnType}Filter {
    search: String         # case-insensitive substring on labelField
    searchPrefix: String   # begins_with — cheaper path when an index exists
    ids: [ID!]             # batch hydration by id
  }
  ```
  Emit the type once per return type, reusing the existing `seenTypes` set.
- [QueryDbResolvers_GraphQL.res](../../reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res) — extend the list resolver at lines 210-256 to read `args.filter`, apply client-side `String.toLowerCase`+`String.includes` on the label column for `search`, `String.startsWith` for `searchPrefix`, and membership check for `ids`. Filtering happens before `first`/`after` pagination.
- [QueryEngine_DynamoDb.res.mjs](../../reventless/reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res.mjs) — wire the filter arg through to `scanByTableName` at line 174. The engine already speaks `Contains` / `BeginsWith` at lines 98-106; translate `{search}` → `Contains`, `{searchPrefix}` → `BeginsWith`, `{ids}` → multiple `Equal` predicates on the primary key combined with `OR` (use `BatchGetItem` if the engine supports it; otherwise N×`GetItem`).
- AWS resolver for the per-plugin list query (grep for `listQueryField` in `reventless-aws/src`) — accept the new arg and pass it to the query engine.

**Concrete steps.**
1. Extend the SDL emitter; verify via schema snapshot test that every list query has the new optional arg.
2. Implement the in-memory filter logic. Label field comes from the Phase 3 `labelField` on the queryable def; the resolver must have the plugin structure in scope (it already does via closure — verify).
3. Implement the DynamoDB filter translation. For `search`, use scan with `FilterExpression`; for `searchPrefix` with a declared GSI on the label column, use query-by-index instead for efficiency. Initially ship scan-only; GSI optimisation is a follow-up.
4. Add resolver tests: filter by `search`, empty search (filter dropped), `ids` batch, combining `filter` + `first`/`after`.
5. Document the semantics in the generator's commentary: `search` is case-insensitive substring, `searchPrefix` is case-insensitive prefix, `ids` is an exact-match set.

**Validation.**
- Schema snapshot: every `${Entity}Filter` input type present; every connection query accepts `filter: ${Entity}Filter`.
- In-memory: `customers(filter: {search: "acme"}, first: 10)` returns customers whose `email` (or configured label) contains "acme", paginated.
- DynamoDB: same query against a deployed AWS platform returns matching rows.
- Empty search string drops the filter entirely (no `contains(x, "")` sent to DynamoDB).

**Commit message.**
`feat!: add filter arg (search, searchPrefix, ids) to Connection list queries`

The `!` marks the rename of `${ReturnType}Filter` → `${ReturnType}ItemsFilter` for items queries, which is a breaking schema change for clients that referenced that type name.

---

## Phase 5 — `@ref` ppx annotation and `Reference` metadata ✅ core implementation landed

**Pairs with UI Phase C.** Nice-to-have. Independent of Phases 1-4.

**Implementation notes.**
- `Reference.res` in `reventless-spec/src/components/` exports `target`, `referenceId`, `to_`, `toWithoutDcbTag`, and `getTarget`. `to_` implies DCB tag metadata; `toWithoutDcbTag` omits it (used when `@ref @noDcbTag` is combined).
- `ReferenceInference.ml` runs before `DcbTagInference.transform_structure` so the injected `@s.matches(Reference.to_(...))` is seen by the auto-`*Id` tagger which then skips the field. The `@ref` attribute is stripped during transformation.
- `@ref("Plugin.Entity")` splits on the first `.`; `@ref("Entity")` produces no plugin qualifier. Self-reference (`@ref` with no payload) raises a clear error — deferred until enclosing-aggregate context is threaded through the ppx.
- `fieldReference` is a `@schema` type in `Plugin.res` with `plugin: @s.matches(stringOptionSchema) option<string>` for JSON-safe serialization.
- `SchemaType.fromSury` now classifies `@ref @noDcbTag` fields as `EntityId` (renders as `ID!` in GraphQL SDL) even when `DcbTag` metadata is absent.
- Platform bootstrap reference validator (plan step 3) deferred — open question 2 row 5 interaction also deferred.
- Both SDL copies in `Platform.res` updated; both encoders extended with `references` array.

**Deferred for follow-up** (not blocking Phase 6 progress):
- Self-reference `@ref` (no payload) — requires threading enclosing aggregate name through ppx transform context.
- Platform bootstrap validator — walk `commandDef.references`, resolve targets against all plugin structures, throw on unknown entity.
- Ppx snapshot tests under `packages/reventless-ppx/test/`.
- End-to-end test: command with `@ref("Customer")` → `Platform_UIDefinitions` returns expected `references` array.

**Context.** The UI heuristic (property name ends in `Id`/`Ids`, stem matches an entity) covers every case in the current examples. Phase 5 replaces the heuristic with an explicit annotation for plugins that have non-`Id` naming, self-references, ambiguous stems, or need disambiguation between same-named entities across plugins. See [auto-ui-entity-reference-dropdowns.md §C](../../../reventless-ui/docs/analysis/auto-ui-entity-reference-dropdowns.md#phase-c--explicit-reference-annotation-via-reventless-ppx) for the full rationale and syntax.

**Goal.** Ship `@ref("EntityName")` as a field-level annotation that survives into `Platform_UICommandDef` as a typed reference list.

**Files to change.**
- New: `reventless/reventless-spec/src/components/Reference.res` — mirrors `DcbTag.res`. Exports `target = {entity: string, plugin: option<string>}`, `referenceId: S.Metadata.Id.t<target>`, `to_: (~plugin=?, string) => S.t<string>`, `getTarget: S.t<unknown> => option<target>`.
- [reventless-ppx/src/ppx/ReferenceInference.ml](../../packages/reventless-ppx/src/ppx/ReferenceInference.ml) — new ppx pass. Reads `@ref(...)` from `ld.pld_attributes` (field-declaration position, before the field name — same as `@partitionTag`/`@dcbTag`) and injects `@s.matches(Reventless.Reference.to_(...))` on `ld.pld_type` (type-attribute position). For `array<string>` fields, the injection targets the element type, matching the existing auto-tag dispatch at [DcbTagInference.ml:117-128](../../packages/reventless-ppx/src/ppx/DcbTagInference.ml#L117-L128). Handles `@ref` (no payload → self-reference, filled in from enclosing aggregate at transform time) and `@ref("Plugin.Entity")` (splits on the dot, sets `~plugin`).
- [ReventlessPpx.ml](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml) — wire the new pass into `transform`. Must run before `strip_ppx_attrs` and after `transform_explicit_dcb_tags` so `@ref` implies `@dcbTag` (auto-inject DCB tagging when `@ref` is present unless `@noDcbTag` is also set).
- [SchemaType.res](../../reventless/reventless-core/src/components/Api/SchemaType.res) — extend `fromSury`'s tag check so a field carrying `Reference` metadata is classified as `EntityId` even when `DcbTag` metadata is absent. Today the check is `Reventless.DcbTag.isTagged(schema)`; widen it to `isTagged(schema) || Reference.getTarget(schema)->Option.isSome`. Without this, `@ref @noDcbTag customerId: string` (open question 2, row 5) would render as `String!` while every other `@ref` field renders as `ID!`. The semantic "this field references an entity" should drive the SDL type regardless of DCB-tag storage concerns.
- [Plugin.res (spec)](../../reventless/reventless-spec/src/components/Plugin.res) — add `references: array<fieldReference>` to `commandDef`:
  ```rescript
  type fieldReference = {
    fieldName: string,
    entity: string,
    plugin: option<string>,
  }
  ```
- [Plugin_Structure.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res) — in `toCommandDef`, walk the command schema and collect `Reference.getTarget` results per property. Emit `references: []` when the schema has no annotations.
- [Platform.res (in-memory)](../../reventless/reventless-in-memory/src/Platform.res) — extend `Platform_UICommandDef` SDL at line 1157 (and its copy at line 1738) with:
  ```graphql
  references: [Platform_UIFieldReference!]!
  ```
  and add:
  ```graphql
  type Platform_UIFieldReference {
    fieldName: String!
    entity: String!
    plugin: String
  }
  ```
  Extend the encoder at lines 1169-1175 to emit the new field.
- Platform bootstrap — after all plugins register, walk every `commandDef.references`, resolve each `{entity, plugin?}` against the union of all plugin structures' aggregates + read-side views. Throw with a clear error if any target doesn't exist.

**Concrete steps.**
1. Build `Reference.res` and its ppx pass. Add ppx snapshot tests for: scalar reference, array reference, self-reference (`@ref` no payload), fully-qualified (`@ref("Plugin.Entity")`).
2. Extend `commandDef` with the `references` field and populate it in `Plugin_Structure`.
3. Add a cross-plugin reference validator in `Platform.makePlatform` (two-pass: collect all structures, validate references). Unresolved reference → clear error naming command, field, spelled target.
4. Extend the SDL and encoder.
5. Update `PluginStructureTest.res` with reference-annotation cases.
6. Extend the SDL snapshot test so a `@ref @noDcbTag` field renders as `ID!` — locks in the `SchemaType.fromSury` fix above.
7. Add an end-to-end test in a fresh example spec: command with `@ref("Customer")` → `Platform_UIDefinitions` query returns the expected `references` array.

**Validation.**
- Ppx tests pass.
- `PluginStructureTest.res` tests pass, including the validator's negative cases.
- Dev-app GraphQL introspection shows `references` on every `Platform_UICommandDef`.
- An intentionally-broken `@ref("Customerrr")` raises a clear error at platform boot.

**Commit message.**
`feat: add @ref ppx annotation for explicit cross-entity field references`

---

## Phase 6 — `@searchable` annotation for indexed text queries

**Pairs with no UI phase directly.** Follow-up to Phase 4. Nice-to-have; ship only when a deployed plugin shows measurable scan cost on `filter.searchPrefix`.

**Context.** Phase 4 ships `filter.search` / `filter.searchPrefix` as scan-only on DynamoDB. That's correct for any predicate but O(all rows) per query. `@searchable` is the opt-in escape hatch: authors mark fields the UI queries by prefix, the adapter provisions a GSI shaped to answer `begins_with` from the index. See [OQ4 below](#4-filter-on-indexed-read-models-resolved-by-phase-6-plus-phase-4-scan-only).

**Goal.** Provide a deploy-time declaration — "this field is text-queryable" — that provisions an appropriate GSI and lets the Phase 4 resolver auto-route `searchPrefix` / exact-match hits through it instead of scanning.

**Scope decisions (non-negotiable).**
- Supports `equals` and `begins_with`. Does **not** support `contains` — DynamoDB cannot answer `contains` from any key condition, only a post-retrieval `FilterExpression`. `filter.search` (substring) stays scan-only regardless of `@searchable`; external full-text search is a separate initiative (see Phase 6.1 below, *deferred*).
- Applies to **any `@schema type state` string field**, not just `@displayName`. The UI's search default targets `@displayName`, but plugins with SKU / reference-number / handle lookups need the same mechanism on non-label fields.
- One GSI per annotated field by default; grouping knob for shared-index scenarios; opt-out knob for "advertise without provisioning."

**Surface.**
```rescript
@schema type state = {
  @id id: string,
  @displayName @searchable firstName: string,
  @displayName @searchable lastName: string,
  @searchable email: string,
  @searchable("skus") sku: string,        // shared group — see below
  @searchable("skus") mpn: string,
  @searchable(indexed=false) internalRef: string,  // metadata only, no GSI
  @index categoryId: string,              // unchanged: exact-match partition-key GSI
}
```

**Semantics.**
- **Plain `@searchable`** — provisions a GSI with a constant/bucketed partition key and the field as the **sort key**. Enables `KeyConditionExpression: begins_with(#sk, :val)` within the partition. `equals` is also O(matches) via the same index.
- **`@searchable("groupName")`** — multiple fields with the same group share one GSI, composed into a multi-segment sort key (`field1#field2`). Cheaper at the cost of coupling — `begins_with` on `field2` alone becomes impossible; only `field1` or `field1#field2` prefixes work. Use when a small set of fields are nearly always queried in the same order (human name, classification hierarchy, etc.).
- **`@searchable(indexed=false)`** — emits the field onto `Platform_UIReadSideDef.searchableFields` (Phase 3) but provisions no GSI. Resolver falls back to scan. Useful on small tables or when authors want to surface the capability to clients before paying the GSI cost.

**Files to change.**
- New: `reventless/reventless-spec/src/components/Searchable.res` — exports `searchableSpec = {group: option<string>, indexed: bool}`, `searchableId: S.Metadata.Id.t<searchableSpec>`, `getSpec: S.t<unknown> => option<searchableSpec>`.
- [reventless-spec/src/ReventlessSpec.res](../../reventless/reventless-spec/src/ReventlessSpec.res) — re-export.
- New: `packages/reventless-ppx/src/ppx/SearchableInference.ml` — rewrite `@searchable[(...)]` field attribute into metadata set on the field's type schema. Collect per-schema the set of annotated fields (with groups) and emit index entries into `let config`'s `indexes` array — same emission point `@index`/`@indexSubId` already uses. One unnamed group per field; named groups aggregate.
- [ReventlessPpx.ml](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml) — wire the pass. Order: after `@ref` (so annotations stack correctly) and alongside `@index` aggregation.
- [Plugin_Structure.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Structure.res) — extend the Phase 3 `searchableFields` population. Now sourced from `Searchable.getSpec` on each state field; include `indexed: false` fields too (they're still UI-searchable, just scan-backed).
- [QueryDbResolvers_GraphQL.res](../../reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res) — route `filter.searchPrefix` through the searchable GSI when one matches the target field. Fallback to scan when no GSI exists (i.e., `indexed: false` or annotation absent).
- [QueryEngine_DynamoDb.res.mjs](../../reventless/reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res.mjs) — emit `KeyConditionExpression` with `begins_with` on the searchable-index sort key. Engine already supports this form (lines 98-106).

**Ppx interactions — errors and warnings.**

| Combination | Handling |
|---|---|
| `@searchable` on non-string field | Ppx error: "only string fields" |
| `@searchable` on `@id` / `@subId` / `@compositeId` / `@compositeSubId` | Ppx error: "primary key fields are exact-match queryable without @searchable" |
| `@searchable` on `@resolves` / `@resolvesMany` | Ppx error: "search the target table, not the resolver" |
| `@index` + `@searchable` on same field | Warning: "two GSIs provisioned (partition-key for @index, sort-key for @searchable); likely unintended" |
| `@indexSubId("name")` + `@searchable` on same field | Warning: "the named index's sort key already supports begins_with within its partition scope; @searchable will provision a second GSI" — authors opt into the redundancy knowingly |
| `@ref` + `@searchable` on same field | Warning: "@ref fields point to another entity; search the target's searchable fields instead" |
| `@displayName` + `@searchable` | Valid common pattern; no diagnostic |
| `@searchable` on the synthetic `displayName` field | Not directly expressible in author code (the field is injected); expose via file-level `@@displayName(searchable: true)` — optional; off by default to avoid over-indexing |

**Concrete steps.**
1. Build `Searchable.res` and the ppx pass. Unit-test the ppx on each row of the table above.
2. Extend the index-aggregation logic in the ppx so `@searchable` emits GSI entries compatible with the existing `indexConfig` shape. Named groups produce one composite-sort-key index; unnamed produce one per field.
3. Update the DynamoDB query engine (if needed) to accept `begins_with` on a searchable-shaped GSI. Verify against a deployed test stack.
4. Update the in-memory resolver to use the same routing logic as DynamoDB — ensures parity between `filter.searchPrefix` behavior across platforms.
5. Extend `PluginStructureTest.res` and the GraphQL schema snapshot to lock in: searchable fields land in `searchableFields`, `indexed=false` fields are listed but no GSI is emitted, groups collapse correctly.
6. Document the 20-GSI DynamoDB cap in the ppx guide's `@searchable` section. Authors need to budget.

**Validation.**
- Ppx tests pass, all interaction rows covered.
- In-memory: `customers(filter: {searchPrefix: "Ada"})` returns matching customers; resolver log shows "index hit" not "scan."
- DynamoDB: CloudWatch shows the searchable GSI handling `begins_with` queries; no scan RCU on annotated tables.
- `filter.search` (substring) still scans with or without `@searchable` — not an index-eligible predicate.
- Grouped fields: `searchPrefix` on the first group member works from the index; on the second member alone falls back to scan (documented trade-off).

**Commit message.**
`feat: add @searchable ppx annotation with DynamoDB GSI provisioning for begins_with`

### Phase 6.1 — external full-text search — *deferred*

Substring / case-insensitive / typo-tolerant search isn't possible on DynamoDB at scale without n-gram explosion or an external service (OpenSearch, Meilisearch, Typesense). Introduce a separate `@fullTextSearchable` annotation wired to an external adapter when a real plugin needs it. Out of scope here; noted only so the naming choice of `@searchable` (DynamoDB-backed) doesn't preclude a future fuller annotation.

---

## Open questions

### 1. `ids: [ID!]` batch performance on DynamoDB

**The constraint.** DynamoDB `BatchGetItem` caps at 100 keys and 16 MB per call; beyond that the caller must page. UI batch sizes aren't uniform:

- **Dropdown hydration** — ≤20 ids (one page of `first: 20`). Comfortably under the cap.
- **`AutoListView` column label preload (UI Phase 5)** — page size × reference columns. A 50-row orders page with 3 reference columns = 150 ids. Over the cap.
- **Multi-select command re-open** — N ids where N is the size of the previously-submitted array. Usually small; worst-case unbounded.

**Options.**

1. **Chunk in parallel inside the adapter.** Split the `ids` array into chunks of 100, issue them concurrently, merge results. Transparent to callers; latency is max(chunk latency) plus merge. Handles unprocessed-item retries uniformly.
2. **Chunk sequentially.** Simpler failure model but slower: for 150 ids, roughly 2× the latency of option 1.
3. **Require the UI to chunk.** Pushes DynamoDB awareness into the client — wrong layer.
4. **Scan with `IN` filter.** `FilterExpression: "id IN (...)"` — full table scan. Horrible at scale.
5. **Cap `ids` at 100 and return a clear error.** Forces the UI to chunk. Inverts responsibility for an avoidable limit.

**Recommendation: option 1.** Chunk transparently in the adapter; the resolver exposes `ids` without a documented cap. Handle `UnprocessedKeys` by retrying with exponential backoff before returning results.

**Moves from open to decided when:** an example plugin ships a list view that preloads labels for >100 ids and a benchmark confirms end-to-end latency stays under ~500 ms with parallel chunking. If a real workload exceeds that, we're probably over-preloading — cap the list page size instead of expanding `BatchGetItem` usage.

### 2. PPX ordering — `@ref` + `@dcbTag` interaction

**The mechanic that decides this.** Sury's `@s.matches(X)` attribute *replaces* a field's schema; it doesn't accumulate. A field can only carry one `@s.matches`. So `@ref("Customer")` must inject a schema that carries *both* DCB tag metadata *and* reference metadata:

```rescript
// Reference.res
let to_ = (~plugin=?, entity: string): S.t<string> =>
  S.string
  ->S.Metadata.set(~id=DcbTag.dcbTagId, true)         // auto-imply DCB tag
  ->S.Metadata.set(~id=referenceId, {entity, plugin})
```

This follows the `DcbTag.partition` pattern verbatim: `partition` stacks both `dcbTagId` and `dcbPartitionTagId` on one schema. The multiple-metadata story works; the multiple-`@s.matches` story doesn't.

**Pass ordering.** `@ref` must run *before* `transform_label_decl` (the auto-`*Id` tagger at [DcbTagInference.ml:106](../../packages/reventless-ppx/src/ppx/DcbTagInference.ml#L106)) so the existing `not (has_s_matches_attr ...)` guard sees the `Reference.to_` attribute and skips. Concretely, insert the new pass in [ReventlessPpx.ml:349](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L349) between `check_deprecated_no_tag` and `transform_structure`.

**Interaction cases that need tests.**

Short-form annotations (`@ref`, `@dcbTag`, `@noDcbTag`) sit **before the field name**; the ppx-injected `@s.matches(...)` attaches to the type after the colon.

| Field declaration (what the author writes) | Expected output (after ppx) | Why |
|---|---|---|
| `@ref("Customer") customerId: string` | `customerId: @s.matches(Reference.to_("Customer")) string` only | Reference wins; DCB tag baked in |
| `@dcbTag customerId: string` | `customerId: @s.matches(DcbTag.string) string` only | No reference; existing behavior |
| `customerId: string` (in slice folder) | `customerId: @s.matches(DcbTag.string) string` via auto-tag | Auto-tag unchanged |
| `@ref("Customer") @dcbTag customerId: string` | `customerId: @s.matches(Reference.to_("Customer")) string` | Redundant `@dcbTag` silently dropped — `Reference` already tags |
| `@ref("Customer") @noDcbTag customerId: string` | `customerId: @s.matches(S.string) string` with only reference metadata | Explicit opt-out wins; test that the DCB auto-tag inside `Reference.to_` is bypassed — may require a `to_WithoutDcbTag` variant |

**Moves from open to decided when:** the ppx test suite covers all five rows above. Row 5 is the thorniest — may need a second `Reference` constructor for the no-DCB variant.

### 3. Labels on state schemas with no labelable fields — *resolved by composite `@displayName`, partial residue*

**Resolution.** Phase 2's composite `@displayName` (multiple annotations combine in declaration order with a separator, projection writes `displayName` into state) supersedes the earlier single-annotation design and absorbs what was originally option 4 below. Authors compose `@displayName firstName` + `@displayName lastName` or `@displayName sku` + `@displayName(", ") name` directly; no `let displayName: state => string` boilerplate and no per-query runtime cost.

**What this does *not* fix.** Schemas that genuinely have *no* field suitable as a label — `ProductDemand: {orderId: string, count: int}` where the only string is a UUID, or `{count: int, updatedAt: int}` where the only scalars are numbers. Composite annotation helps when multiple string fields exist; it can't invent a labelable field when none does.

**Residual options.**

1. **Fall back to `id`, display UUIDs.** Cheap, honest, ugly. Plugin author adds a projected label field if/when it matters (trivially: compute it in the projection body, declare it in state, annotate with `@displayName`). Recommended.
2. **Per-type auto-formatting** — e.g., turn `{count: int}` into `"3 items"` via convention. Rules accrete, fragile, opinionated. Avoid.
3. **Ppx error when no string field and no `@displayName` exists.** Forces authors to confront the problem up front. Breaks existing plugins on upgrade and penalizes legitimate "this thing has no natural label" cases (counters, metrics, aggregated views). Avoid.

**Recommendation: option 1.** The composite design covers the cases we actually care about (multi-field names, addresses, compound labels); schemas without any labelable field are rare and the author's escape hatch — project a label field — is a handful of lines.

**Moves from open to decided when:** composite `@displayName` lands (Phase 2). The "no string fields at all" case is then just the `"id"`-fallback branch of the Phase 3 source ladder with a logged warning, which is enough. Reopen only if we see plugins shipping computed-label workarounds that motivate a first-class `let displayName: state => string` hook.

### 4. Filter on indexed read models — *resolved by Phase 6 plus Phase 4 scan-only*

**Resolution.** Phase 4 ships `filter.search` / `filter.searchPrefix` as scan-backed on every read model — correct for any predicate, priced against table size. Phase 6 introduces `@searchable` as the opt-in escape hatch: authors mark fields that need indexed prefix queries; the adapter provisions a GSI sort-keyed on the field; the resolver auto-routes `searchPrefix` through the index when available, falls back to scan otherwise. The distinction is predicate-based:

- `filter.searchPrefix` — `begins_with`. Indexed when `@searchable` is present. Scan-only otherwise.
- `filter.search` — substring. **Always scan-only on DynamoDB**, `@searchable` or not. DynamoDB cannot answer substring predicates from any key condition. External full-text search is deferred to a future `@fullTextSearchable` annotation (Phase 6.1).
- Exact match on `@searchable` fields also benefits from the GSI; no separate annotation needed.

**What stays open.** Nothing blocking. Two follow-on judgment calls will surface in practice:

1. **Grouping defaults.** Does `@displayName @searchable` on multiple fields produce one GSI per field, or auto-group into a shared sort key (`firstName#lastName`)? Phase 6's default is one GSI per field — cleanest semantics, pays for isolation. Promote grouping to an opt-in knob (`@searchable("group")`) and revisit the default if GSI budget pressure appears in practice.
2. **Auto-route on existing `@index` fields.** A field already carrying `@indexSubId("name")` is a sort key of a named index and could answer `begins_with` within that index's partition scope. The Phase 6 resolver ignores this — routes only through `@searchable`-provisioned GSIs — because the preconditions (caller supplies the partition value, partition has enough cardinality) are non-trivial to check automatically. Revisit if plugins start paying for redundant `@searchable` GSIs on fields that already have a partition-scoped index.

**Moves from open to decided when:** Phase 6 lands. Both residual questions become concrete engineering calls with measurable inputs (GSI count per table, scan RCU vs provisioned throughput) rather than speculative design trade-offs.