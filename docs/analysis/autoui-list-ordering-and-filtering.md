# AutoUI List Ordering and Filtering

**Status:** Analysis of current behaviour and the gaps in default-changing affordances.

Companion implementation history: `docs/plans/done/autoui-schema-annotations.md`, `docs/plans/done/autoui-server-query-capabilities.md`.

---

## Scope

Every queryable component (`ReadModel/`, `StateViewSlice/`, `StateViewSliceStream/`) gets an auto-generated GraphQL connection field of the shape

```graphql
listField(
  filter: <Type>Filter,
  orderBy: <Type>OrderBy,
  first: Int, after: String,
  last: Int, before: String
): <Type>Connection!
```

The AutoUI client renders a list view over that field, driven entirely by the JSON Schema attached to the read model. This document describes:

1. The defaults the framework applies when the request is bare (no `filter`, no `orderBy`).
2. Which annotations change which defaults.
3. Where the work runs — server (resolver) vs client (browser).
4. What you currently *cannot* change by annotation, and what that would take.

---

## How capability is derived

A read model's JSON Schema carries `x-reventless-*` extension keys for every structural annotation on its `@schema type state`. `GraphQL_FragmentGenerator.deriveServerCapability` reads those keys and returns a `serverCapability` of `{ filterFields, sortFields }`. The same function is consumed by:

- The SDL emitter (`deriveConnectionFilterType`, `deriveConnectionOrderByType`) — decides which `<field>Eq` / `<field>From` / `<field>To` inputs appear and whether an `OrderBy` input exists at all.
- The in-memory resolver (`QueryDbResolvers_GraphQL.res`) — decides which filter args it parses and which fields it accepts for `orderBy`.
- The AWS resolver wiring (`QueryDbResolvers_AppSync.res`) — bakes the same set into the deploy-time JS resolver template (Phase 3a of the server-query plan).

One source of truth. The schema fully determines the surface; the resolvers cannot drift from it.

---

## Defaults today

### Default filter

There isn't one. A bare request returns every row in the read model, subject only to pagination.

Three filter inputs are *always present* on every connection, regardless of annotation:

- `search: String` — substring match against the schema-level "summary" fields (`@id`, `@compositeId` parts, `@summary` fields). O(n) in-memory; on AWS this runs as a Scan + `FilterExpression`.
- `searchPrefix: String` — same set, prefix match.
- `ids: [ID!]` — exact match against the encoded global ID; falls back to the bare local id so callers can hydrate by local key.

Per-field `<field>Eq` (and `<field>From` / `<field>To` for range fields) appear only when the field is in the capability set.

### Default order

When `orderBy` is omitted:

| Backend | Order |
|---|---|
| In-memory | **id ascending** — deterministic and stable so keyset cursors decode reliably. This is hard-coded in `QueryDbResolvers_GraphQL.res:493`. |
| AWS DynamoDB | Whatever the underlying `Scan` returns (indeterminate). When `orderBy` *is* supplied, the JS resolver does a per-page sort on the returned slice. |

Notable: the two backends diverge here. There is no annotation that sets a *per-read-model default sort*. Whoever wants "newest first" today has to pass `orderBy: { field: createdAt, direction: DESC }` from the caller (URL param, fragment variable, etc.) or rely on the UI client to set it.

### Default page size

`defaultListPageSize = 50`, hard-coded at the top of `QueryDbResolvers_GraphQL.res`. Used only when neither `first` nor `last` is supplied. There is no per-read-model annotation. Callers override per-request via the standard Relay args.

---

## Annotations that affect filter / sort

### Native (auto-derived, no opt-in)

Every structural annotation on `@schema type state` participates:

| Annotation | Filter effect | Sort effect | AWS cost |
|---|---|---|---|
| `@id` | `idEq: ID` | sortable (the table partition key — only useful in conjunction with cursor) | O(1) via `GetItem`-style routing |
| `@compositeId` | per-part `<part>Eq: <Scalar>` | not sortable (composite parts are partition-key segments, not a sort dimension) | O(1) prefix Query |
| `@subId` / `@compositeSubId` | `<field>Eq`, `<field>From`, `<field>To` | sortable | O(log n) Query |
| `@index` / `@index("name")` | `<field>Eq` | sortable (the GSI's sort key) | O(1) per-GSI Query (v1.5: today it's still Scan + Filter on AWS, see Phase 3) |

These need no opt-in because there's an underlying physical index. The cost is the same on every adapter.

### Opt-in (cost-acceptance)

`@scan` and `@scanSort` add filter / sort capability for fields that have *no* backing index. They exist because:

- On the in-memory adapter, filter/sort over arbitrary fields is free, so the only thing the annotation does is widen the SDL.
- On AWS, the same widening commits the deploy to a `Scan + FilterExpression` (for `@scan`) or a JS-runtime per-page sort over a full Scan (for `@scanSort`). That's a real cost — the annotation is the explicit signal that the author has decided it's acceptable.

| Annotation | What it does | AWS cost |
|---|---|---|
| `@scan` | Adds `<field>Eq` to the Filter input. | O(n) `Scan + FilterExpression` |
| `@scanSort` | Adds the field to the `OrderField` enum. | Full-table Scan + per-page JS sort |

A deploy-time warning fires for `@scanSort` fields that aren't aligned with a known sort key (Phase 3b shipped). The deploy still succeeds; the warning is the explicit "this is expensive" signal.

### Visibility (affects which columns the AutoUI list renders, not the SDL)

These change the AutoUI *presentation* of list rows, not the GraphQL surface:

| Annotation | Effect |
|---|---|
| `@summary` | Field always appears in summary / list views. Also folded into the `search` / `searchPrefix` field set. |
| `@hidden` | Field does not appear in summary / list views. |
| `@@reventless.visibility(Internal)` | File-level: hides the entire component from the AutoUI manifest. |

`@summary` is the closest thing to "default column" — it's what shows up in the list table without the user clicking a column-picker. It is not a sort or filter directive.

---

## Client vs server, and what decides which

The UI auto-generates a Relay-style query whose shape is fixed by the schema, then chooses where to evaluate filter / sort based on what the schema actually exposes:

| Field has capability for the requested operation? | Where it runs |
|---|---|
| Yes (annotated, in `capability.filterFields` / `sortFields`) | **Server.** The request includes `filter.<field>Eq` or `orderBy.field`; the resolver narrows / sorts; cursors paginate the narrowed set. |
| No | **Client fallback.** The full result (per page) is returned, and the UI filters / sorts in the browser. Pagination then degrades to client-only paging over what arrived. |

`search` / `searchPrefix` / `ids` always run server-side because they're always in the SDL.

There is no per-request override that says "I want this client-side even though it's available server-side." If the capability exists, the UI uses it.

### Cursor stability across the two backends

Both adapters use keyset cursors. In-memory cursors encode the value of `orderBy.field` (or `id` when no `orderBy`), with an id tiebreak so duplicate sort values don't collide. AWS encodes DynamoDB's `LastEvaluatedKey`. The fact that the in-memory default-order is *id ascending* (not "insertion order" or "natural") is precisely so the cursor decode stays deterministic when no `orderBy` is supplied. Don't change that fallback casually — the resolver tests assert it.

### Caveat: AWS per-page sort

`orderBy` on AWS sorts within the returned page only, because DynamoDB Scan returns indeterminate order and `ScanIndexForward` is Query-only. Paging through multiple pages with `@scanSort` reveals an inconsistent global order. The deploy-time warning surfaces this; the v1.5 index-promotion phase (out of scope here) is what eliminates it for fields that *are* a sort key of some index.

---

## What you cannot change today by annotation — and what would be needed

### Default sort

**Today.** Hard-coded: id-asc (in-memory) or Scan-natural (AWS). Callers must pass `orderBy` to override.

**Gap.** No `@defaultSort("createdAt", #desc)` annotation exists. A reasonable design would:

1. Add `defaultSort: option<(string, [#asc | #desc])>` to `stateAnnotationSpec`.
2. PPX recognises `@@reventless.defaultSort("field", #desc)` (file-level) and writes it into the metadata.
3. `deriveServerCapability` carries it through.
4. The resolver applies it when `orderBy` is `None`, before pagination. The cursor field becomes that same field with id-tiebreak — matches the existing pattern.
5. Validation: the field must already be in `sortFields` (i.e. backed by `@id`/`@subId`/`@index`/`@scanSort`). Otherwise compile error.

The AutoUI client would still let the user re-sort interactively; the default only applies when no explicit `orderBy` is in the URL.

### Default filter

**Today.** None pre-applied.

**Gap.** No `@defaultFilter` annotation. A reasonable design would carry a small expression (`{ field: "status", eq: "active" }`) through the same metadata path, applied unconditionally before user-supplied filter args. The interesting question is whether the user can *clear* it from the UI (separate "predicate" pane?) or whether it's invisible. Probably worth deferring until a concrete use case appears — most "default filter" needs are better served by an explicit purpose-built read model (e.g. `ActiveOrders` rather than `Orders` with a default filter for `status = active`).

### Default page size per read model

**Today.** Global constant `defaultListPageSize = 50` in `QueryDbResolvers_GraphQL.res:38`.

**Gap.** A `@@reventless.defaultPageSize(N)` file-level annotation would propagate through the same metadata channel and be read by the resolver's pagination block. Cheap to implement; the call for this typically comes from very-wide rows or unusually-narrow ones where 50 is the wrong number.

### Per-field default direction

**Today.** Resolver always applies `ASC` unless the request explicitly says `DESC`.

**Gap.** Probably better folded into `@defaultSort` (which already carries direction) than as a separate annotation.

---

## Further opportunities

Beyond the missing default-changing annotations, the current model leaves several other shapes on the table. Listed roughly in order of value-to-effort.

### Richer filter primitives

- **`@scanRange` (or extend `@scan` with `range: true`).** `@scan` today only emits `<field>Eq`. Numeric / date / version columns commonly want `<field>From` / `<field>To`. The `serverCapability.filterFields[].range` flag already exists; only the annotation surface and the metadata-write are missing. Same code path as `@subId` range filters.
- **Typed enum filter inputs.** When a field is a ReScript polymorphic variant or has `@s.enum`, the SDL currently lowers it to `<field>Eq: String`. Emitting `<field>Eq: <FieldEnum>` would let the UI render a dropdown automatically, would catch invalid values at request-validation time, and would make the GraphQL schema honest about the domain. `SchemaType.fromSuryObject` already knows the variant cases.
- **`In` filters.** `<field>In: [<Scalar>!]` for multi-select facets — currently the UI has to issue N requests or fall back to client-side. A single `[<field> in (a, b, c)]` is cheap in both adapters.
- **Composite indexed filter (`@compositeIndex(["status", "ownerId"])`).** Today a UI that wants "open orders for owner X" issues one `<field>Eq` and either filters the other client-side or relies on luck that one of the two is indexed. A composite-index annotation that maps to a GSI with a composite sort key would close the gap and is structurally similar to `@compositeSubId`.

### Sort flexibility

- **Multi-field `OrderBy`.** Today the SDL emits `input <Type>OrderBy { field: ..., direction: ... }` — a single field. List views commonly want "primary by X desc, secondary by Y asc" (e.g. group by status, then by createdAt). Changing the SDL to `[<Type>OrderBy!]` is a one-line widening; the in-memory resolver's comparator already does id-tiebreak and would extend to N-tiebreak naturally; the AWS per-page sort comparator extends the same way.
- **Sortable composite-id parts.** `@compositeId` parts are deliberately excluded from `sortFields` because they're partition-key segments. But for `(yyyy, mm)` style keys, sorting by the leading part is meaningful. An explicit `@sortablePart` (or auto-detect when the part is a sortable scalar) would let those cases work without forcing the author to duplicate the field as `@scanSort`.

### Search

- **Opt-out of built-in `search`.** Some read models have no meaningful summary text; the always-on `search` / `searchPrefix` inputs are dead surface and, on AWS, a footgun (someone wires the UI search box, ships, and discovers it does a Scan + FilterExpression). A file-level `@@reventless.noSearch` would let the SDL omit them.
- **`@fullText` for real search.** The current `search` is substring/prefix Scan — fine for ≤ 10k rows, useless beyond. Annotating a read model as `@@reventless.fullText` could signal a separate adapter (OpenSearch / Algolia / SQLite FTS depending on the platform) that backs the same `search` field. Out-of-band component, but the annotation is the natural binding point.

### AWS adapter parity

These are already flagged in `docs/plans/done/autoui-server-query-capabilities.md` as open questions; restating here so the analysis is self-contained:

- **Index-routed Query promotion (Phase 3 v1.5).** When the request shape matches a single GSI's key, dispatch `Query` instead of `Scan + FilterExpression`. The biggest perf win available without changing any annotation.
- **`GetItem` short-circuit for `idEq`-only requests** on connections. Today the connection resolver Scans + Filters; the auto-generated `byId(id:)` field does the right thing. The connection path could short-circuit when the only arg is `idEq`.
- **Backward pagination on AWS.** Resolver returns `pageInfo.hasPreviousPage = false`, so the UI hides the back arrow. DynamoDB needs `ScanIndexForward` flipping + boundary-swap + result reverse — non-trivial but doable, and the asymmetry with the in-memory adapter is visible to anyone who runs dev locally.
- **`totalCount`.** Relay's `pageInfo` has no `totalCount`. A `Scan(Select=COUNT)` round-trip (or a denormalised counter) would unlock "Showing 1–50 of N" — a frequent UX ask. Cheapest as an opt-in `@countable` annotation so the cost is owned per read model.

### Saved / preset views

- **`@savedView("Active", { filter: {...}, orderBy: {...} })`** as a file-level repeatable annotation. The AutoUI client renders one tab/chip per saved view; clicking a tab is equivalent to navigating to the URL-encoded form of that filter+sort. This is the "pre-canned dashboard" use case that today people solve by spinning up a separate read model (`ActiveOrders`) or hand-rolling a panel. Annotations let the same physical read model carry N curated entry points without duplication.
- This also reframes the `@defaultFilter` gap: a "default view" is just the first `@savedView` flagged as default. Probably cleaner than a standalone `@defaultFilter`.

### Manifest / presentation hints

- **`@listColumn(order: N, width: "200px")`** for explicit column ordering / sizing in the default list table. Today the order follows declaration order in `@schema type state`; widths are evenly distributed. Neither is wrong but both are common asks once a list grows past 5–6 visible columns.
- **`@formatAs("currency" | "duration" | "date" | "bytes" | ...)`** to drive cell rendering without the UI having to guess from field names. Aligns with the existing `@summary` / `@hidden` visibility hints — same metadata channel, additional fields.

### Schema-author escape hatches

- **`@@reventless.allowedFilterFields([...])` / `allowedSortFields([...])`** as an explicit allow-list that *overrides* the auto-derivation. Useful when a field has `@index` for query-routing reasons but the author doesn't want it in the SDL surface (e.g. an internal sort key). Today there's no way to suppress; capability is purely additive from annotations.
- **`@clientOnly` filter hint per call site (GraphQL directive).** Lets a UI explicitly say "evaluate this filter client-side this time" — useful when an experiment needs to A/B against the server's evaluation, or when the server-side cost is unexpectedly high for one specific caller. Lower priority because the right answer is usually to fix the schema, but it's a clean escape hatch.

---

## Quick reference

| Want to … | Today |
|---|---|
| Filter a list by an indexed field | Add `@index` (or use `@id` / `@subId`); SDL gains `<field>Eq` automatically |
| Filter a list by a non-indexed field | Add `@scan` (accepts the AWS Scan cost) |
| Sort a list by an indexed field | Same as above — `@index` / `@subId` make it sortable for free |
| Sort a list by a non-indexed field | Add `@scanSort` (accepts the per-page-sort caveat on AWS) |
| Hide a field from the list view | `@hidden` |
| Always show a field in the list view | `@summary` |
| Hide the entire component from AutoUI | `@@reventless.visibility(Internal)` |
| Substring search across summary fields | Built-in; always works |
| Change the default sort order | **No annotation today** — caller must pass `orderBy` |
| Change the default filter | **No annotation today** — author can model a narrower read model instead |
| Change the default page size | **No annotation today** — caller passes `first` / `last` |
| Force client-side evaluation despite server capability | **Not supported** — capability always wins when present |

---

## References

- `reventless/core/src/components/Api/GraphQL_FragmentGenerator.res` — `deriveServerCapability`, `deriveConnectionFilterType`, `deriveConnectionOrderByType`, `validateScanSortAlignment`.
- `reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` — `defaultListPageSize`, filter/sort/keyset-cursor implementation.
- `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` — capability lookup at deploy time, JS resolver template wiring.
- `rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` — `listAllItemsConnection` template (filter expression assembly, per-page sort, range clauses).
- `reventless/spec/src/components/StateAnnotations.res` — `stateAnnotationSpec` (the metadata record that the PPX populates and the schema-emitter consumes).
- `docs/plans/done/autoui-schema-annotations.md` — Phases 1–4: how structural annotations reach the JSON Schema.
- `docs/plans/done/autoui-server-query-capabilities.md` — Phases 1–3: how the JSON Schema becomes the filter / sort / pagination surface.
