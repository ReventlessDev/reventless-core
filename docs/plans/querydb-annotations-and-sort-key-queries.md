# Plan: QueryDb Annotations and Sort Key Queries

**Analysis:** `private-consumer-repo/docs/analysis/querydb-design-patterns.md`

**Scope:** Extend `reventless-ppx`, framework specs, builders, storage adapters, and resolvers
to support declarative `@schema type state` annotations for composite keys, GSI indexes,
cross-table resolvers, and sort key query conditions. All features work identically for both
`ReadModel` and `StateViewSlice`.

---

## Phase 1 — `@subId` and `@compositeSubId` (main table sort key)

### 1.1 PPX: `@subId` on `@schema type state` record fields

- [ ] Add a new `Ptype_record` walker to `DcbTagInference.ml` (or a new `StateAnnotations.ml`)
      that processes `@schema` record types (not variant types)
- [ ] Detect `@subId` on exactly one string field; generate
      `let subIdConfig = Some({ subIdField: "fieldName", getSubId: state => state.fieldName })`
- [ ] When no `@subId` is present, inject `let subIdConfig = None`
- [ ] Strip `@subId` from the output AST
- [ ] Validate: error if `@subId` appears on more than one field, or on a non-string field

### 1.2 PPX: `@compositeSubId` on multiple record fields

- [ ] Detect multiple fields annotated `@compositeSubId`; collect in declaration order
- [ ] Generate `let subIdConfig = Some({ subIdField: "_subId", getSubId: state => \`${f1}/${f2}/...\` })`
- [ ] Support optional `~sep` parameter (default `/`)
- [ ] Strip `@compositeSubId` from the output AST
- [ ] Validate: error if `@subId` and `@compositeSubId` both appear

### 1.3 `StateViewSlice.Spec`: add `subIdConfig` field

- [ ] Add `let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>>` to
      `StateViewSlice.Spec` module type in `reventless-spec`

### 1.4 `StateViewSlice_Builder`: forward `subIdConfig`

- [ ] Change `let subIdConfig = None` to `let subIdConfig = Spec.subIdConfig` in
      `StateViewSlice_Builder.SvQueryDbSpec`

### 1.5 `QueryDb_Operations`: inject computed sub-ID

- [ ] In `save` and `saveBatch`, after encoding state to JSON dict, inject
      `getSubId(state)` under `subIdField` when `subIdConfig` is `Some`
- [ ] This is a no-op for single-field `@subId` (field already in JSON) but essential
      for `@compositeSubId`

### 1.6 `QueryDbStorage_InMemory`: composite-key semantics

- [ ] Change in-memory store from `dict<array<JSON.t>>` to `dict<dict<JSON.t>>`
      (partition → subId → item)
- [ ] Use implicit sub-key `""` when no `subIdField` is present
- [ ] Implement `loadStream` to return items sorted by sub-key
- [ ] Implement `delete` and `deleteBatch` to target `(partitionKey, subId)` pairs

### 1.7 Tests: `@subId` and `@compositeSubId`

- [ ] PPX snapshot test: `@subId` on one field → generated `subIdConfig` with direct accessor
- [ ] PPX snapshot test: `@compositeSubId` on multiple fields → generated composite accessor
- [ ] PPX snapshot test: no sub-ID annotation → generated `let subIdConfig = None`
- [ ] PPX error test: `@subId` + `@compositeSubId` on same type → compile error
- [ ] PPX error test: `@subId` on non-string field → compile error
- [ ] Integration test: StateViewSlice with `@subId` — project, query `{name}ById`, verify
      grouped results
- [ ] Integration test: StateViewSlice with `@compositeSubId` — project with composite
      sort key, verify `_subId` attribute in stored items, verify `{name}ById` returns all
- [ ] Integration test: ReadModel with `@subId` — same as above, verify parity
- [ ] In-memory storage test: `loadStream` returns items sorted by sub-key
- [ ] In-memory storage test: `delete(partitionKey, subId)` removes correct item, not
      entire partition

---

## Phase 2 — `@id` and `@compositeId` (main table partition key)

### 2.1 PPX: `@id` on one record field

- [ ] Detect `@id` on one field; generate `let makeId = (state: state) => state.fieldName`
- [ ] Strip `@id` from output AST

### 2.2 PPX: `@compositeId` on multiple record fields

- [ ] Detect multiple `@compositeId` fields; collect in declaration order
- [ ] Generate `let makeId = (state: state) => \`${f1}/${f2}/...\``
- [ ] Support optional `~sep` parameter (default `/`)
- [ ] Strip `@compositeId` from output AST

### 2.3 Tests: `@id` and `@compositeId`

- [ ] PPX snapshot test: `@id` on one field → `let makeId` with direct accessor
- [ ] PPX snapshot test: `@compositeId` on 2+ fields → `let makeId` with concatenation
- [ ] PPX snapshot test: `@compositeId(~sep=":")` → custom separator
- [ ] PPX error test: `@id` + `@compositeId` on same type → compile error
- [ ] PPX error test: `@id` on non-string field → compile error

---

## Phase 3 — `@index` and `@indexSubId` (GSI annotations)

### 3.1 PPX: standalone `@index` (single-field GSI, no sort key)

- [ ] Detect unnamed `@index` on a field; generate index entry with field as pk,
      no sort key, ALL projection
- [ ] Infer DynamoDB `type_` from ReScript field type (`string` → `"S"`, `int`/`float` → `"N"`)
- [ ] Support `~projection=KEYS_ONLY` and `~include=["f1", "f2"]` parameters

### 3.2 PPX: named `@index("name")` with `@indexSubId("name")` (GSI with sort key)

- [ ] Collect all `@index("name")` fields with the same name — grouped by name, first field
      is pk, subsequent fields form composite pk (concatenated)
- [ ] Collect `@indexSubId("name")` fields — single or multiple for composite sort key
- [ ] For composite pk or composite sk: generate synthetic attribute name
      (`"_indexName_pk"`, `"_indexName_sk"`) and computed accessor
- [ ] `QueryDb_Operations` injects computed values (same mechanism as `@compositeSubId`)

### 3.3 PPX: authorization parameters on `@index`

- [ ] Support `~group="GroupName"` and `~authTable="TableName"` parameters on the first
      `@index("name")` occurrence
- [ ] Generate `authorization: Some({ group, tableName })` in the `indexConfig`

### 3.4 PPX: generate `let config`

- [ ] Aggregate all `@index`, `@indexSubId`, `@resolves`, `@resolvesMany` into
      `let config = ReadModel.config(~indexes=[...], ~idResolvers=[...], ~idsResolvers=[...])`
- [ ] When no annotations present, inject `let config = ReadModel.config()` (empty default)

### 3.5 `StateViewSlice.Spec`: add `config` field

- [ ] Add `let config: ReadModel.config` to `StateViewSlice.Spec`
- [ ] `StateViewSlice_Builder`: forward `Spec.config` to `QueryDb_Builder`

### 3.6 Tests: `@index` and `@indexSubId`

- [ ] PPX snapshot test: standalone `@index` → index entry, field = pk, ALL projection
- [ ] PPX snapshot test: `@index(~projection=KEYS_ONLY)` → KEYS_ONLY
- [ ] PPX snapshot test: `@index("name")` + `@indexSubId("name")` → index with pk + sk
- [ ] PPX snapshot test: composite `@index("name")` on 2 fields → composite pk
- [ ] PPX snapshot test: composite `@indexSubId("name")` on 2 fields → composite sk
- [ ] PPX snapshot test: `@index(~group, ~authTable)` → authorization populated
- [ ] PPX snapshot test: no index annotations → `let config = ReadModel.config()`
- [ ] PPX error test: `@indexSubId("name")` without matching `@index("name")` → error
- [ ] Integration test: StateViewSlice with `@index` — verify GSI created in DynamoDB
- [ ] Integration test: ReadModel with `@index("name")` + `@indexSubId("name")` — verify
      composite GSI query works

---

## Phase 4 — `@resolves` and `@resolvesMany` (cross-table resolvers)

### 4.1 PPX: `@resolves`

- [ ] Detect `@resolves(~to="TableName", ~as="fieldName")` on a string field
- [ ] Generate `idResolverConfig` entry in `config.idResolvers`
- [ ] Support `~via="indexName"`, `~plugin="PluginName"`, `~sourceSubId="field"`,
      `~subIdArg="argName"` parameters

### 4.2 PPX: `@resolvesMany`

- [ ] Detect `@resolvesMany(~to="TableName", ~as="fieldName")` on an `array<string>` field
- [ ] Generate `idsResolverConfig` entry in `config.idsResolvers`

### 4.3 Tests: `@resolves` and `@resolvesMany`

- [ ] PPX snapshot test: `@resolves(~to, ~as)` → idResolverConfig with Id target
- [ ] PPX snapshot test: `@resolves(~to, ~as, ~via)` → idResolverConfig with Index target
- [ ] PPX snapshot test: `@resolvesMany(~to, ~as)` → idsResolverConfig
- [ ] PPX snapshot test: multiple annotations on one field (`@compositeId` + `@resolves`) →
      both outputs generated independently
- [ ] Integration test: ReadModel with `@resolves` — verify virtual field resolvable

---

## Phase 5 — `@noDcbTag` rename

### 5.1 PPX: rename `@noTag` → `@noDcbTag`

- [ ] In `DcbTagInference.ml`, change the attribute name string from `"noTag"` to `"noDcbTag"`
- [ ] Strip `@noDcbTag` from output AST (already done for `@noTag`)
- [ ] Update all existing spec files in `reventless-core` that use `@noTag`

### 5.2 Tests

- [ ] PPX snapshot test: `@noDcbTag` suppresses auto-tagging on `*Id` field
- [ ] PPX error test: `@noTag` (old name) produces a clear deprecation error

---

## Phase 6 — Sort key query conditions on `{name}ById`

### 6.1 SDL: add sort key arguments and Connection return type

- [ ] In `QueryDbResolvers_AppSync.res`: generate `{name}ByIdConnection` type and updated
      `{name}ById` query with `prefix`, `from`, `to`, `eq`, `reverse`, `limit`, `nextToken`
      arguments when `subIdField` is `Some`
- [ ] In `QueryDbResolvers_GraphQL.res`: generate identical SDL for in-memory

### 6.2 AppSync: `queryByIdWithSortConditions` template

- [ ] Add `queryByIdWithSortConditions(sortField)` to `AppSync_Resolver_Functions.res`
      with the if-else chain handling all six DynamoDB sort key operators
- [ ] Update `QueryDbResolvers_AppSync.res` to use new template when `subIdField` is Some
- [ ] Response function returns `{ items, nextToken }`

### 6.3 In-memory: sort key filtering

- [ ] In `QueryDbResolvers_GraphQL.res`: after `loadStream`, apply sort key filter
      (`eq`, `prefix`, `from`/`to`), `reverse`, `limit`, `nextToken` (offset-based)
- [ ] Return `{ items, nextToken }` matching AppSync behaviour

### 6.4 Tests: sort key conditions

- [ ] Integration test: `{name}ById(id)` — all items ascending
- [ ] Integration test: `{name}ById(id, prefix)` — `begins_with`
- [ ] Integration test: `{name}ById(id, from)` — `>= from`
- [ ] Integration test: `{name}ById(id, from, to)` — `BETWEEN from AND to`
- [ ] Integration test: `{name}ById(id, eq)` — exact sort key match
- [ ] Integration test: `{name}ById(id, reverse: true)` — descending
- [ ] Integration test: `{name}ById(id, limit: 5)` — page size
- [ ] Integration test: `{name}ById(id, reverse: true, limit: 3)` — last 3 items
- [ ] Integration test: pagination with `nextToken` — verify continuation

---

## Phase 7 — Guide, documentation, and skills

### 7.1 Create `querydb-key-design-guide.md`

- [ ] Create `/docs/guides/querydb-key-design-guide.md` covering:
  - ReadModel vs StateViewSlice decision (when to use which)
  - Key pattern decision flowchart (singleton → entity-keyed → versioned → composite)
  - `@id` / `@compositeId` usage with generic examples
  - `@subId` / `@compositeSubId` usage with generic examples
  - `@index` / `@indexSubId` for GSIs with generic examples
  - `@resolves` / `@resolvesMany` for cross-table joins
  - Sort key query conditions (`prefix`, `from`/`to`, `eq`, `reverse`, `limit`)
  - Combining current state + audit log (sentinel sort key pattern)
  - Lexicographic sort key caveats (unpadded versions, ISO timestamps)
- [ ] Review `/docs/guides/aggregate-vs-dcb-decision-guide.md` — extract any overlapping
      ReadModel-vs-StateViewSlice content, link to new guide instead of duplicating
- [ ] Review `/packages/doc/docs-app/concepts/stateviewslice-usage.md` — add cross-reference
      to new guide for key design patterns

### 7.2 Update existing doc pages

- [ ] Update `/packages/doc/docs-app/components/readmodel.md` — add section on `@subId`,
      `@index`, `@resolves` annotations replacing manual config
- [ ] Update `/packages/doc/docs-app/components/stateviewslice.md` — add section noting
      parity with ReadModel for annotations (same `@subId`, `@index` support)
- [ ] Update `/packages/doc/docs-app/components/querydb.md` — add section on composite
      keys and sort key queries
- [ ] Update `/docs/guides/reventless-ppx.md` — add all new annotations
      (`@id`, `@compositeId`, `@subId`, `@compositeSubId`, `@index`, `@indexSubId`,
      `@resolves`, `@resolvesMany`, `@noDcbTag`)

### 7.3 Add to Reventless Skills plugin

- [ ] Add `references/querydb-key-patterns.md` to
      `/.claude-plugin/reventless-skills/skills/reventless-app/references/`
      covering annotation-driven key design, generic examples for each pattern,
      sort key query arguments
- [ ] Update `references/dcb-patterns.md` — add `@subId` / `@index` annotations to
      StateViewSlice code templates
- [ ] Update `references/component-catalog.md` — add `subIdConfig`, `config` fields to
      StateViewSlice spec definition; add annotation descriptions

### 7.4 Remove duplications

- [ ] Check `/packages/doc/docs-app/concepts/stateviewslice-usage.md` vs new guide —
      move key-related content to new guide, keep usage doc focused on projection logic
- [ ] Check `/docs/guides/dcb-usage.md` — remove any key pattern discussion, link to guide
