# Plan: QueryDb Annotations and Sort Key Queries

**Analysis:** `private-consumer-repo/docs/analysis/querydb-design-patterns.md`

**Scope:** Extend `reventless-ppx`, framework specs, builders, storage adapters, and resolvers
to support declarative `@schema type state` annotations for composite keys, GSI indexes,
cross-table resolvers, and sort key query conditions. All features work identically for both
`ReadModel` and `StateViewSlice`.

---

## Phase 1 — `@subId` and `@compositeSubId` (main table sort key)

### 1.1 PPX: `@subId` on `@schema type state` record fields

- [x] Add a new `Ptype_record` walker to `DcbTagInference.ml` (or a new `StateAnnotations.ml`)
      that processes `@schema` record types (not variant types)
- [x] Detect `@subId` on exactly one string field; generate
      `let subIdConfig = Some({ subIdField: "fieldName", getSubId: state => state.fieldName })`
- [x] When no `@subId` is present, inject `let subIdConfig = None`
- [x] Strip `@subId` from the output AST
- [x] Validate: error if `@subId` appears on more than one field, or on a non-string field

### 1.2 PPX: `@compositeSubId` on multiple record fields

- [x] Detect multiple fields annotated `@compositeSubId`; collect in declaration order
- [x] Generate `let subIdConfig = Some({ subIdField: "_subId", getSubId: state => \`${f1}/${f2}/...\` })`
- [x] Support optional `~sep` parameter (default `/`)
- [x] Strip `@compositeSubId` from the output AST
- [x] Validate: error if `@subId` and `@compositeSubId` both appear

### 1.3 `StateViewSlice.Spec`: add `subIdConfig` field

- [x] Add `let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>>` to
      `StateViewSlice.Spec` module type in `reventless-spec`

### 1.4 `StateViewSlice_Builder`: forward `subIdConfig`

- [x] Change `let subIdConfig = None` to `let subIdConfig = Spec.subIdConfig` in
      `StateViewSlice_Builder.SvQueryDbSpec`

### 1.5 `QueryDb_Operations`: inject computed sub-ID

- [x] In `save` and `saveBatch`, after encoding state to JSON dict, inject
      `getSubId(state)` under `subIdField` when `subIdConfig` is `Some`
- [x] This is a no-op for single-field `@subId` (field already in JSON) but essential
      for `@compositeSubId`

### 1.6 `QueryDbStorage_InMemory`: composite-key semantics

- [x] Change in-memory store from `dict<array<JSON.t>>` to `dict<dict<JSON.t>>`
      (partition → subId → item)
- [x] Use implicit sub-key `""` when no `subIdField` is present
- [x] Implement `loadStream` to return items sorted by sub-key
- [x] Implement `delete` and `deleteBatch` to target `(partitionKey, subId)` pairs

### 1.7 Tests: `@subId` and `@compositeSubId`

- [x] PPX snapshot test: `@subId` on one field → generated `subIdConfig` with direct accessor
- [x] PPX snapshot test: `@compositeSubId` on multiple fields → generated composite accessor
- [x] PPX snapshot test: no sub-ID annotation → generated `let subIdConfig = None`
- [x] PPX error test: `@subId` + `@compositeSubId` on same type → compile error
- [x] PPX error test: `@subId` on non-string field → compile error
- [x] Integration test: StateViewSlice with `@compositeSubId` — project with composite
      sort key, verify `_subId` attribute in stored items, verify `{name}ById` returns all
- [ ] Integration test: StateViewSlice with `@subId` — project, query `{name}ById`, verify
      grouped results
- [ ] Integration test: ReadModel with `@subId` — same as above, verify parity
- [x] In-memory storage test: `loadStream` returns items sorted by sub-key
- [x] In-memory storage test: `delete(partitionKey, subId)` removes correct item, not
      entire partition

---

## Phase 2 — `@id` and `@compositeId` (main table partition key)

### 2.1 PPX: `@id` on one record field

- [x] Detect `@id` on one field; generate `let makeId = (state: state) => state.fieldName`
- [x] Strip `@id` from output AST

### 2.2 PPX: `@compositeId` on multiple record fields

- [x] Detect multiple `@compositeId` fields; collect in declaration order
- [x] Generate `let makeId = (state: state) => \`${f1}/${f2}/...\``
- [x] Support optional `~sep` parameter (default `/`)
- [x] Strip `@compositeId` from output AST

### 2.3 Tests: `@id` and `@compositeId`

- [x] PPX snapshot test: `@id` on one field → `let makeId` with direct accessor
- [x] PPX snapshot test: `@compositeId` on 2+ fields → `let makeId` with concatenation
- [x] PPX snapshot test: `@compositeId(~sep=":")` → custom separator
- [x] PPX error test: `@id` + `@compositeId` on same type → compile error
- [x] PPX error test: `@id` on non-string field → compile error

---

## Phase 3 — `@index` and `@indexSubId` (GSI annotations)

### 3.1 PPX: standalone `@index` (single-field GSI, no sort key)

- [x] Detect unnamed `@index` on a field; generate index entry with field as pk,
      no sort key, ALL projection
- [x] Infer DynamoDB `type_` from ReScript field type (`string` → `"S"`, `int`/`float` → `"N"`)
- [x] Support `projection: "KEYS_ONLY"` and `fields: ["f1", "f2"]` (for `INCLUDE`) in record form
      (Note: `include` is a reserved word; `fields` used instead)

### 3.2 PPX: named `@index("name")` with `@indexSubId("name")` (GSI with sort key)

- [x] Collect all `@index("name")` fields with the same name — grouped by name, first field
      is pk, subsequent fields form composite pk (concatenated)
- [x] Collect `@indexSubId("name")` fields — single or multiple for composite sort key
- [x] For composite pk or composite sk: generate synthetic attribute name
      (`"_indexName_pk"`, `"_indexName_sk"`) in the `indexConfig`
- [x] `QueryDb_Operations` injects computed synthetic attribute values into saved JSON
      via `injectCompositeIndexAttrs` (reads `pkFields`/`skFields` from `indexConfig`)

### 3.3 PPX: authorization parameters on `@index`

- [x] Support `group: "GroupName"` and `authTable: "TableName"` in record-form `@index({...})`
- [x] Generate `authorization: { group, tableName }` in the `indexConfig`

### 3.4 PPX: generate `let config`

- [x] Aggregate all `@index`, `@indexSubId` into
      `let config = ReadModel.config(~indexes=[...])`
- [x] When no annotations present, inject `let config = Reventless.ReadModel.config()` (empty default)

### 3.5 `StateViewSlice.Spec`: add `config` field

- [x] Add `let config: ReadModel.config` to `StateViewSlice.Spec`
- [x] `StateViewSlice_Builder`: forward `Spec.config` to `QueryDb_Builder` (`SvQueryDbSpec`)

### 3.6 Tests: `@index` and `@indexSubId`

- [x] PPX snapshot test: standalone `@index` → index entry, field = pk, ALL projection
- [x] PPX snapshot test: `@index({projection: "KEYS_ONLY"})` → KEYS_ONLY
- [x] PPX snapshot test: `@index({projection: "INCLUDE", fields: [...]})` → INCLUDE
- [x] PPX snapshot test: `@index("name")` + `@indexSubId("name")` → index with pk + sk
- [x] PPX snapshot test: composite `@index("name")` on 2 fields → composite pk + pkFields
- [x] PPX snapshot test: composite `@indexSubId("name")` on 2 fields → composite sk + skFields
- [x] PPX snapshot test: `@index({group, authTable})` → authorization populated
- [x] PPX snapshot test: no index annotations → `let config = ReadModel.config()`
- [x] PPX error test: `@indexSubId("name")` without matching `@index("name")` → error
- [ ] Integration test: StateViewSlice with `@index` — verify GSI created in DynamoDB
- [ ] Integration test: ReadModel with `@index("name")` + `@indexSubId("name")` — verify
      composite GSI query works

---

## Phase 4 — `@resolves` and `@resolvesMany` (cross-table resolvers)

### 4.1 PPX: `@resolves`

- [x] Detect `@resolves({table: "TableName", field: "fieldName"})` on a string field
      (Note: `~to`/`~as` are ReScript reserved words; record syntax `{table, field}` used instead)
- [x] Generate `idResolverConfig` entry in `config.idResolvers`
- [x] Support `via`, `plugin`, `sourceSubId`, `subIdArg` record fields

### 4.2 PPX: `@resolvesMany`

- [x] Detect `@resolvesMany({table: "TableName", field: "fieldName"})` on an `array<string>` field
- [x] Generate `idsResolverConfig` entry in `config.idsResolvers`

### 4.3 Tests: `@resolves` and `@resolvesMany`

- [x] PPX snapshot test: `@resolves({table, field})` → idResolverConfig with Id target
- [x] PPX snapshot test: `@resolves({table, field, via})` → idResolverConfig with Index target
- [x] PPX snapshot test: `@resolvesMany({table, field})` → idsResolverConfig
- [x] PPX snapshot test: multiple annotations on one field (`@compositeId` + `@resolves`) →
      both outputs generated independently
- [ ] Integration test: ReadModel with `@resolves` — verify virtual field resolvable

---

## Phase 5 — `@noDcbTag` rename

### 5.1 PPX: rename `@noTag` → `@noDcbTag`

- [x] In `DcbTagInference.ml`, change the attribute name string from `"noTag"` to `"noDcbTag"`
- [x] Strip `@noDcbTag` from output AST (already done for `@noTag`)
- [x] Update all existing spec files in `reventless-core` that use `@noTag`

### 5.2 Tests

- [x] PPX snapshot test: `@noDcbTag` suppresses auto-tagging on `*Id` field
- [x] PPX error test: `@noTag` (old name) produces a clear deprecation error

---

## Phase 6 — Sort key query conditions on `{name}ById`

### 6.1 SDL: add sort key arguments and Connection return type

- [x] In `QueryDbResolvers_AppSync.res`: generate `{name}ByIdConnection` type and updated
      `{name}ById` query via `GraphQL_FragmentGenerator` (adds `subIdField` to `querySchemaEntry`,
      generates `{returnTypeName}ByIdConnection` type + sort key query field with all args)
- [x] In `QueryDbResolvers_GraphQL.res`: generate identical SDL for in-memory
      (returns `${returnTypeName}ByIdConnection!` with all args)

### 6.2 AppSync: `queryByIdWithSortConditions` template

- [x] Added `queryByIdWithSortConditions(sortField)` to `AppSync_Resolver_Functions.res`
      with if-else chain: `eq`, `prefix` (begins_with), BETWEEN (`from`+`to`), `>= from`, `<= to`
- [x] Updated `QueryDbResolvers_AppSync.res` to use new template when `subIdField` is Some
- [x] Response function returns `{ items: ctx.result.items, nextToken: ctx.result.nextToken }`

### 6.3 In-memory: sort key filtering

- [x] Extracted `SortKey_Filter.apply` pure helper in `src/adapter/QueryDb/SortKey_Filter.res`
- [x] In `QueryDbResolvers_GraphQL.res`: uses `SortKey_Filter.apply` after `loadStream`
- [x] Returns `{ items, nextToken }` where `nextToken` is an offset-based cursor

### 6.4 Tests: sort key conditions

- [x] Unit tests for `SortKey_Filter.apply`: all items, prefix, from, to, BETWEEN, eq,
      reverse, limit, pagination with `nextToken`, prefix+pagination, reverse+limit, no match
- [ ] Integration test: full GraphQL `{name}ById` query with sort conditions (requires
      GraphQL test harness — defer until full E2E test infrastructure is available)

---

## Phase 7 — Guide, documentation, and skills

### 7.1 Create `querydb-key-design-guide.md`

- [x] Create `/docs/guides/querydb-key-design-guide.md` covering:
  - ReadModel vs StateViewSlice decision (when to use which)
  - Key pattern decision flowchart (singleton → entity-keyed → versioned → composite)
  - `@id` / `@compositeId` usage with generic examples
  - `@subId` / `@compositeSubId` usage with generic examples
  - `@index` / `@indexSubId` for GSIs with generic examples
  - `@resolves` / `@resolvesMany` for cross-table joins
  - Sort key query conditions (`prefix`, `from`/`to`, `eq`, `reverse`, `limit`)
  - Combining current state + audit log (sentinel sort key pattern)
  - Lexicographic sort key caveats (unpadded versions, ISO timestamps)
- [x] Review `/docs/guides/aggregate-vs-dcb-decision-guide.md` — no key design overlap found
- [x] Review `/packages/doc/docs-app/concepts/stateviewslice-usage.md` — added cross-reference
      to new guide for key design patterns

### 7.2 Update existing doc pages

- [x] Update `/packages/doc/docs-app/components/readmodel.md` — add section on `@subId`,
      `@index`, `@resolves` annotations replacing manual config
- [x] Update `/packages/doc/docs-app/components/stateviewslice.md` — add section noting
      parity with ReadModel for annotations (same `@subId`, `@index` support)
- [x] Update `/packages/doc/docs-app/components/querydb.md` — add section on composite
      keys and sort key queries
- [x] Update `/docs/guides/reventless-ppx.md` — add all new annotations
      (`@id`, `@compositeId`, `@subId`, `@compositeSubId`, `@index`, `@indexSubId`,
      `@resolves`, `@resolvesMany`, `@noDcbTag`)

### 7.3 Add to Reventless Skills plugin

- [x] Add `references/querydb-key-patterns.md` to
      `/.claude-plugin/reventless-skills/skills/reventless-app/references/`
      covering annotation-driven key design, generic examples for each pattern,
      sort key query arguments
- [x] Update `references/dcb-patterns.md` — add `@subId` / `@index` annotations to
      StateViewSlice code templates
- [x] Update `references/component-catalog.md` — add `subIdConfig`, `config` fields to
      StateViewSlice spec definition; add annotation descriptions

### 7.4 Remove duplications

- [x] Check `/packages/doc/docs-app/concepts/stateviewslice-usage.md` vs new guide —
      no key design content found, added cross-reference link
- [x] Check `/docs/guides/dcb-usage.md` — no key design overlap (covers DCB EventLog partitioning, different concept)
