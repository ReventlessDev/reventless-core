# Plan: Server-Side Filter / Sort / Pagination Capabilities

Pairs with the UI-side work tracked in [reventless-ui/docs/plans/autoui-improvements-ui.md § Phase 6.5](../../../reventless-ui/docs/plans/autoui-improvements-ui.md#phase-65--server-side-filter--sort--pagination-hybrid).

**Goal.** Extend the auto-generated GraphQL query surface so list views can filter, sort, and paginate on the server using the existing Relay-style connection. The list field already accepts `filter: <Type>Filter, first, after, last, before`; today's `<Type>Filter` only carries `search / searchPrefix / ids`. This plan widens it with per-field equality (auto-derived from existing structural annotations) and a typed `OrderBy` input, plus a single new `@scan` / `@scanSort` opt-in for fields that should also be filterable/sortable without an underlying index.

The UI consumes the new inputs via Phase 6.5; the schema author only writes new annotations when they explicitly want scan-based filtering or sorting.

---

## Capability tiers

The schema's existing structural annotations (Phase 1 of [autoui-schema-annotations.md](autoui-schema-annotations.md)) already describe which fields are *natively* server-queryable — i.e. backed by an index in any reasonable backend implementation. Two tiers cover the design space:

| Tier | Trigger annotation | Filter | Sort | Cost on in-memory | Cost on AWS |
|---|---|---|---|---|---|
| Native — primary key | `@id` | eq | default order | O(1) | O(1) |
| Native — composite parts | `@compositeId` | eq, prefix on first part | n/a (sort key drives order) | O(1) | O(1) prefix |
| Native — sort key | `@subId` / `@compositeSubId` | range | yes | O(log n) | O(log n) |
| Native — secondary index | `@index(name?)` | eq | yes (the GSI's sort key) | O(1) | O(1) (per GSI) |
| Scan filter | **NEW** `@scan` | eq | n/a | O(n) Array.filter | O(n) `Scan + FilterExpression` |
| Scan sort | **NEW** `@scanSort` | n/a | yes | O(n log n) | full-table read |
| Schema-level `search` | derived: any string `@id` / `@summary` / `@compositeId` part | substring | n/a | O(n) | O(n) Scan |

Native is always cheap. Scan is intentionally an opt-in because it's asymmetric: free on the in-memory adapter, costly on DynamoDB. The schema author opts in when they know the read model is small or the cost is acceptable.

Order in the result is decided once: `orderBy` always wins when supplied, otherwise the connection's natural order (sort-key ascending) is used. This matches the current behaviour for connections that don't pass `orderBy`.

---

## Phase 1 — Auto-derive Filter and OrderBy from existing annotations

**Status.** Shipped.

**Depends on:** [autoui-schema-annotations.md](autoui-schema-annotations.md) Phase 1 (structural annotations propagated into the JSON Schema as `x-reventless-*` extension properties — already shipped).

**Goal.** Extend the connection's `<Type>Filter` SDL with a per-field `eq` for every natively indexable field, add a typed `<Type>OrderBy` input listing the fields that can drive server-side ordering, and wire the in-memory resolver to honour both. No new annotations — capability is fully derived from `@id`, `@compositeId`, `@subId`, `@compositeSubId`, `@index`. Read models without indexed fields keep emitting the existing search-only filter (full backwards compat).

**Files to change.**

- **[reventless-spec/src/components/StateAnnotations.res](../../reventless/reventless-spec/src/components/StateAnnotations.res)** — No change. The `stateAnnotationSpec` already carries `ids`, `compositeIds`, `subIds`, `compositeSubIds`, `indexes`. The Phase 1 change reads from this existing spec.
- **[reventless-core/src/components/Api/SuryToJsonSchema.res](../../reventless/reventless-core/src/components/Api/SuryToJsonSchema.res)** — No change. `x-reventless-id`, `x-reventless-compositeId`, `x-reventless-subId`, `x-reventless-compositeSubId`, `x-reventless-index` are already emitted.
- **[reventless-core/src/components/Api/GraphQL_FragmentGenerator.res](../../reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res)** — Two SDL emitters change:
  - `deriveConnectionFilterType` (currently at line 128, emitting `{ search, searchPrefix, ids }`) gains an extra block of per-field `eq` inputs:
    ```
    input <Type>Filter {
      search: String
      searchPrefix: String
      ids: [ID!]
      idEq: ID                     # @id field (when present)
      <indexedField>Eq: <Scalar>   # one per @index field
      <subIdField>Eq: <Scalar>     # @subId field (when present)
      <subIdField>From: <Scalar>   # @subId range filter
      <subIdField>To: <Scalar>     # @subId range filter
      <compositeIdPart>Eq: <Scalar> # one per @compositeId part
    }
    ```
  - **New: `deriveConnectionOrderByType`** — emits an `enum <Type>OrderField` listing field names that can drive server sorting (every `@id`, `@subId`, `@compositeSubId`, `@index` field — composite-id parts are *not* included because they are part of the partition key, not a sort dimension), plus a `SortOrder` enum (already exists for the items connection) and an `input <Type>OrderBy { field: <Type>OrderField!, direction: SortOrder! }`. Skipped entirely when no field is sortable.
  - `deriveConnectionQueryField` gains an `orderBy: <Type>OrderBy` arg when the OrderBy type was emitted:
    ```
    listField(filter: <Type>Filter, orderBy: <Type>OrderBy, first: Int, after: String, last: Int, before: String): <Type>Connection!
    ```
- **[reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res](../../reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res)** — The list resolver (around line 250) extends its existing filter parsing:
  - For each per-field `<field>Eq` arg present, narrow `items` by exact-match against the row's `<field>` value (string compare via `JSON.Encode.string` round-trip; numeric compare via `JSON.Decode.number`).
  - For range args (`<subIdField>From / To`), narrow by lexical range on the stringified value.
  - When `orderBy` is supplied, sort the narrowed list before pagination using the field-name + direction; ties broken by `@id` to keep keyset cursors stable. When omitted, fall back to the existing default order (sort-key asc).
  - All of these run *before* the existing pagination slice, so cursors continue to encode the sort-key value and remain compatible with `first/after/last/before`.
- **New helper: `deriveServerCapability(schema): { filterFields, sortFields, hasSearch }`** in `GraphQL_FragmentGenerator.res` (or split into a sibling module) — single source of truth for which fields participate in Filter / OrderBy. Both the SDL emitter and the resolver consume it so they cannot drift out of sync.

**Concrete steps.**

1. Read the JSON Schema at SDL-generation time to compute the capability set (`filterFields`, `sortFields`, `hasSearch`). Use the same `x-reventless-*` extension lookups that the UI's `SchemaAnnotations.res` uses, kept in sync via a shared list of extension key constants (a new `Reventless.SchemaExtensions` module if needed).
2. Extend `deriveConnectionFilterType` to emit the per-field `eq` block for every `filterFields` entry. Skip the block when empty (so a read model with only `search`-eligible fields keeps the current SDL byte-for-byte).
3. Implement `deriveConnectionOrderByType`. Emit only when `sortFields` has at least one entry; skip the `orderBy` arg on the connection field when emission was skipped.
4. Update `deriveConnectionQueryField` to splice in the `orderBy` arg when present.
5. Update the in-memory resolver to parse the new args. Carve filter parsing into a small helper (`narrowItems(items, filterDict, capability)`) so the existing `search`/`searchPrefix`/`ids` branches and the new per-field `eq`/range branches share one code path.
6. Sort handler: a `sortItems(items, orderBy, capability)` helper that returns a stable comparator. When `orderBy` is `None`, return `items` unchanged.
7. Add SDL inspector tests in [GraphQL_SchemaInspectorTest.res](../../reventless/reventless-in-memory/tests/adapter/GraphQL_SchemaInspectorTest.res) verifying:
   - A read model with no indexable fields emits the unchanged `{ search, searchPrefix, ids }` Filter.
   - A read model with an `@id` field and one `@index` field emits both `idEq` and `<index>Eq` plus an `<Type>OrderBy` enum listing the same fields.
   - The list field signature includes the `orderBy` arg when emission applies.
8. Add resolver behavioural tests covering `idEq`, `<index>Eq`, range on `@subId`, and `orderBy` ascending/descending. Combine `idEq` + `orderBy` to verify they compose. Include a "no orderBy" baseline that returns the natural sort-key order.

**Validation.**

- ✅ Existing connection-using queries keep working byte-for-byte when the read model has no indexable fields (Filter SDL unchanged, no `orderBy` arg).
- ✅ New per-field `eq` filters narrow rows server-side; `pageInfo` and cursors stay correct.
- ✅ `orderBy` reorders the server-side result; cursor decoding still works because the cursor is already keyed by sort key value.
- ✅ AWS in-memory parity: the AWS resolver path (still in [Platform.res](../../reventless/reventless-in-memory/src/Platform.res) for direct `connectionResponse` calls) either honours the same args or explicitly returns an "unsupported filter" error (TBD in Phase 3 — out of scope for Phase 1).

**Implementation notes (shipped).**

- `serverCapability`, `emptyCapability`, `deriveServerCapability`, `deriveConnectionFilterType`, `deriveConnectionOrderByType`, and `deriveConnectionQueryField (~hasOrderBy)` live in `GraphQL_FragmentGenerator.res`.
- `Plugin_Helpers.stateSchemaRegistry` carries the `S.t<unknown>` for each registered read model; populated in `Plugin_Builder.res` and `Dcb_Builder.res` next to the existing `queryFieldNamesRegistry` writes.
- The in-memory resolver (`QueryDbResolvers_GraphQL.res`) reads the schema from the registry, calls `deriveServerCapability`, and uses the same SDL emitters so its registered SDL stays in lockstep with the fragment SDL. Filter parsing applies per-field `Eq` / `From` / `To` alongside the existing `search` / `searchPrefix` / `ids` block; `orderBy` sorts the narrowed list (id-tiebreak) before pagination.
- SDL coverage: 3 new cases in `GraphQL_SchemaInspectorTest.res` — no annotations (unchanged Filter), `@id` + `@index` (per-field Eq + OrderBy + `orderBy` arg), `@subId` (Eq/From/To + OrderBy on the sort key). Full suites green: 365 in-memory tests, 302 core tests.

---

## Phase 2 — `@scan` and `@scanSort` opt-in for non-indexed fields

**Status.** Planned.

**Depends on:** Phase 1.

**Goal.** Allow the type author to opt fields *without* a backing index into server-side filtering and/or sorting. On in-memory this is a free convenience (the resolver can already filter/sort arbitrary fields); on a future AWS implementation it becomes the explicit signal that the cost is acceptable.

The two annotations are split because their cost profiles differ — `@scan` reads the full table once to filter; `@scanSort` reads the full table and then sorts O(n log n). A type author may want the cheaper one without committing to the more expensive one.

**Files to change.**

- **[reventless-spec/src/components/StateAnnotations.res](../../reventless/reventless-spec/src/components/StateAnnotations.res)** — Extend `stateAnnotationSpec` with two fields:
  ```rescript
  scan: array<string>,         // @scan field names
  scanSort: array<string>,     // @scanSort field names
  ```
- **[reventless-ppx/src/ppx/StateAnnotations.ml](../../packages/reventless-ppx/src/ppx/StateAnnotations.ml)** — Recognise the new attributes (`has_scan_field_attr`, `has_scan_sort_field_attr`), strip them from the source via the existing `strip_visibility_attrs` pattern (pattern naming TBD — `strip_capability_attrs`), and write the collected names into the metadata record.
- **[reventless-core/src/components/Api/SuryToJsonSchema.res](../../reventless/reventless-core/src/components/Api/SuryToJsonSchema.res)** — `mergeAnnotations` emits `"x-reventless-scan": true` / `"x-reventless-scanSort": true` on the matching field schemas.
- **[reventless-core/src/components/Api/GraphQL_FragmentGenerator.res](../../reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res)** — `deriveServerCapability` (introduced in Phase 1) starts including `@scan` fields in `filterFields` and `@scanSort` fields in `sortFields`. The SDL emission, the OrderBy enum, and the resolver narrow/sort helpers all flow through automatically.
- **[reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res](../../reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res)** — No additional code path; `narrowItems` and `sortItems` from Phase 1 already operate on arbitrary fields. The annotation only changes which fields *the SDL exposes*, not how the resolver evaluates them. Document this explicitly in a comment so future readers don't add a redundant scan code path.

**Concrete steps.**

1. PPX extension. Replicate the `@hidden` / `@summary` integration from Phase 2 of `autoui-schema-annotations.md`. Add a negative test ensuring `@scan` and `@scanSort` are stripped from the output source code.
2. Sury metadata extension. Expand `stateAnnotationSpec`. Update `getSpec` consumers — the Phase 1 `deriveServerCapability` helper.
3. JSON Schema emission. Extend `mergeAnnotations` and add unit cases to `SuryToJsonSchemaTest.res`.
4. Capability derivation. `deriveServerCapability` reads the new extension keys and folds the field names into `filterFields` / `sortFields`.
5. SDL inspector tests. A `@scan`-annotated `status` field appears as `statusEq: String` on the Filter input. A `@scanSort`-annotated `name` field appears in the `OrderField` enum.
6. Resolver regression test. Filter by `statusEq` and order by `name` — verify both work without any change to the resolver code itself (Phase 1's `narrowItems` / `sortItems` already cover them).

**Validation.**

- ✅ A field annotated `@scan` becomes filterable via `<field>Eq` in the Filter input.
- ✅ A field annotated `@scanSort` becomes sortable via `orderBy.field`.
- ✅ Combinations work: `@scan` + `@index` on the same field is a contradiction-free no-op (the field would already be in `filterFields` via `@index`).
- ✅ Read models without `@scan` / `@scanSort` continue to emit only the natively-derived Filter / OrderBy from Phase 1.

---

## Phase 3 — AWS adapter (extended Scan + index-routed Query)

**Status.** Planned.

**Depends on:** Phases 1 and 2.

**Goal.** Make the AWS DynamoDB-backed adapter honour the Filter / OrderBy inputs that Phase 1 and 2 added to the SDL. The shared SDL is identical across backends, so any client that targets in-memory will work against AWS the moment Phase 3 ships — no client-side branching, no schema fork.

**Background — what's there today.** The AWS list resolver at [AppSync_Resolver_Functions.res:419 `listAllItemsConnection`](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res) (in `rescript-pulumi-aws`) is **already** a `Scan` with a JS-runtime `FilterExpression` for `search / searchPrefix / ids`. Per-field `eq` therefore extends an existing Scan path; it does not introduce Scan as a new mechanism. Index-routed queries also already exist (`queryByIndex`, `queryByIndexSort`, `queryByIndexFiltered`) — they are wired separately for entity-reference lookups and similar single-key access patterns. Phase 3 unifies the two: the same connection field can serve a Scan (general case) or be promoted to a Query when the request structurally matches a single-index lookup.

**Approach.**

The connection field stays bound to one resolver. Inside the resolver we widen the FilterExpression and (for `orderBy`) flip `ScanIndexForward` when it aligns with the table/GSI sort key. Index promotion (using a GSI when the request hits exactly one indexed field's `eq`) is a follow-up optimisation, not a v1 requirement.

| Request shape | v1 mechanism | Cost | Note |
|---|---|---|---|
| No filter, no `orderBy` | Scan | full-table | unchanged from today |
| `idEq` | `GetItem` | O(1) | already exists; routed via `byId(id:)` query, redundant on connection — see open question 1 |
| Single `<indexField>Eq` | Scan + FilterExpression | O(n) | v1.5 promotes to `Query` on the GSI |
| `<subIdField>From/To` | Scan + FilterExpression | O(n) | v1.5 promotes to `Query` with key-condition |
| `search` / `searchPrefix` / `ids` | Scan + FilterExpression | O(n) | unchanged from today |
| `<scanField>Eq` | Scan + FilterExpression | O(n) | same code path as `<indexField>Eq` — `@scan` only changes SDL gating |
| `orderBy` aligned with table sort key | Scan with `ScanIndexForward=false` for DESC | same as Scan | direction toggle only |
| `orderBy` on `@scanSort` field | Scan + JS-runtime sort over the **page** | full scan + per-page sort | clearly wrong for a global ordering — see open question 2 |

**Files to change.**

- **[rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res)** — Extend `listAllItemsConnection`:
  1. **Per-field `*Eq` filter expressions.** The deploy-time emitter already takes `~labelField`. Add a new parameter `~filterFields: array<string>` (the same set Phase 1's `deriveServerCapability` produces). Inside the JS resolver template, iterate the `filter` object's keys: for any `<field>Eq` whose `<field>` is in `filterFields`, append `#<field> = :<field>` to the expression. Same for `<field>From` / `<field>To` (range) and (future) `<field>In` (`IN` clause).
  2. **`orderBy` direction flip.** New parameter `~sortFields: array<string>` and a `~tableSortField: string` (the read model's natural DynamoDB sort key, typically `@subId` or `@compositeSubId`). When `args.orderBy` is provided AND `orderBy.field === tableSortField`, set `ScanIndexForward` accordingly. When it doesn't match, fall back to JS-runtime sort over the returned page (with a comment marking this as a known limitation — see open question 2).
  3. **Cursor stays `args.after` → `nextToken`.** Backward (`before` / `last`) deferred — see open question 3.
- **[reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res](../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)** — Around line 176 where `listAllItemsConnection(~labelField)` is called, also pass the new `~filterFields` and `~sortFields` derived from the same `deriveServerCapability` helper that Phase 1 added. The AppSync resolver is deploy-time generated, so the supported field set is baked into the resolver code at deploy time — no runtime introspection, no surprise.
- **New: `validateBackendCompatibility(schema, ~backend)`** in `GraphQL_FragmentGenerator.res` (or a sibling) — called during AWS deploy. Emits a Pulumi log warning when a schema declares `@scanSort` on a field that isn't the natural sort key of any table or GSI, naming the read model and field. The deploy still succeeds; the warning is the explicit signal that the request will be expensive in production. (No env-level `ALLOW_SCAN` gate in v1 — annotations are already explicit.)
- **[reventless-aws/tests/](../../reventless/reventless-aws/tests/)** — Add adapter integration tests using the existing test harness (look for analogous tests around `QueryDbResolvers_AppSync`):
  - List with `<indexField>Eq` returns narrowed rows.
  - List with `orderBy.field=<tableSortField>&direction=DESC` returns reverse-ordered rows.
  - List with `<scanSort>` field returns rows sorted within the page (acknowledging the limitation).
  - List with `idEq` continues to work alongside the existing `byId` query path.

**Concrete steps.**

1. Extend `listAllItemsConnection` with `~filterFields` and `~sortFields` parameters and the new JS resolver branches. Keep the existing `search / searchPrefix / ids` block working byte-for-byte so existing connections stay identical when no new fields are present.
2. Wire `QueryDbResolvers_AppSync.res` to compute the capability set per read model at deploy time and pass it through.
3. Add the validation pass for `@scanSort` mismatches. Make the warning unconditional but non-fatal.
4. Adapter integration tests (DynamoDB Local).
5. Document the new args in the resolver-function file's docstring (already a convention there) and in the autoui guide.

**Validation.**

- ✅ Existing AWS deployments without any new annotations behave identically (resolver template extended only when `~filterFields` is non-empty / `~sortFields` is non-empty).
- ✅ A read model with `@index("byOwner")` on `ownerId`: querying with `filter.ownerIdEq="…"` returns only matching rows. v1 uses Scan + FilterExpression; v1.5 promotes to a Query against the `byOwner` GSI.
- ✅ A read model with `orderBy.field` aligned to the natural table sort key: `direction: DESC` reverses the order via `ScanIndexForward=false`.
- ✅ A read model with `@scanSort` on a non-key field: rows come back sorted within the page; deploy-time warning is logged.
- ✅ Cursor pagination (`first / after`) keeps working through all of the above. Backward pagination (`before / last`) intentionally returns `null` cursors — open question 3.

**Open questions.**

1. **Connection-level `idEq` vs the existing `byId` field.** The Phase 1 SDL adds `idEq: ID` to the connection's Filter, but the auto-generated `byId(id: ID!)` query already handles the same access pattern more cheaply (`GetItem` vs `Scan`). v1 includes `idEq` in the Filter input for SDL uniformity but the AWS resolver could short-circuit `idEq`-only requests to a `GetItem` plus a synthetic single-edge connection. v1.5 follow-up.
2. **Global ordering vs per-page ordering with `@scanSort`.** A scan returns up to `limit` items per request and the cursor encodes the LastEvaluatedKey, not the sort position. Sorting *within* the page is per-page, not global — clicking through pages will reveal an inconsistent order. The deploy-time warning makes this visible; a future "small-table" annotation (e.g. `@bounded(maxRows: 1000)`) could trigger a single full-scan-then-sort-then-paginate-in-memory implementation. Out of scope here.
3. **Backward pagination on AWS.** DynamoDB doesn't support reverse cursors directly. To honour `before / last` we'd need to flip `ScanIndexForward`, swap which boundary the cursor encodes, and reverse the result. Doable but adds a non-trivial branch. v1 leaves the `before / last` args in the SDL (they're mandated by Relay) but returns `pageInfo.hasPreviousPage = false` from AWS so the UI's `<Pagination>` simply hides the back arrow.
4. **`totalCount`.** Reintroducing `totalCount: Int` on the connection for AWS would require a `Scan(Select=COUNT)` round trip per page (or a separate GraphQL field). Likely a separate plan; flagged here only so that a future "Showing 1–50 of N" UI ask can find the design rationale.
5. **Index-routed promotion (v1.5).** When the request shape *exactly* matches a single GSI (one `<indexField>Eq` plus optional `orderBy` aligned to that GSI's sort key), the resolver could dispatch `Query` instead of `Scan`. This needs either a pipeline resolver or a runtime branch inside the JS resolver. Both work; the branch keeps the resolver count down. Optional v1.5.

---

## Cross-repo dependency snapshot

```
reventless-core (this plan)            reventless-ui (autoui-improvements-ui.md)
─────────────────────────────────      ──────────────────────────────────────
Phase 1 (auto-derive Filter/OrderBy) ──┐
   │                                   │
   ▼                                   ▼
Phase 2 (@scan / @scanSort opt-in) ─→ Phase 6.5 (hybrid client pipeline)
   │                                   │
   ▼                                   │
Phase 3 (AWS adapter — Scan + ──────────┘  (no client change required)
        index promotion)
```

The UI side (Phase 6.5) lands incrementally:
- It picks up native capability the moment Core Phase 1 ships, against the in-memory adapter.
- It picks up the `@scan` / `@scanSort` story the moment Core Phase 2 ships.
- Core Phase 3 brings AWS to parity — no client change required because the SDL is shared. A schema annotated under Phases 1 & 2 will already produce the right GraphQL shape; Phase 3 just wires the AWS resolver to honour it.
