# Plan: `@searchable` provisions an index for prefix search on a view field

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/entity-reference-dropdowns.md](../done/entity-reference-dropdowns.md) (its Phase 6) when it closed. Waits for evidence: build it only when a deployed view shows measurable Scan cost on `filter.searchPrefix`.<br/>
**Relates to:** [aws-fulllist-ordered-index-promotion.md](aws-fulllist-ordered-index-promotion.md), [reference-and-display-name-hardening.md](reference-and-display-name-hardening.md)

---

## In plain words

Every list query takes `filter: {search, searchPrefix, ids, …}`. On DynamoDB that
filter is applied to a **Scan** — a read of the whole table, filtered afterwards
(`AppSync_Resolver_Functions.res`, the list-all resolver; `search` becomes
`contains`, `searchPrefix` becomes `begins_with` on the view's `labelField`). It
is correct for any predicate, and it costs reads in proportion to the table, not
to the answer. A combobox searching a few thousand rows pays for all of them on
each keystroke.

`@searchable` is the opt-in fix for the prefix case: mark a state field, and the
deployment provisions a GSI (a secondary index) sorted by that field, so
`begins_with` becomes a key condition that reads only matching rows.

## The design the parent plan settled

The full surface, semantics and the table of ppx errors and warnings are in the
parent's Phase 6. In short:

- Supports exact match and `begins_with`, **not** substring. `filter.search`
  stays scan-only whatever is annotated; DynamoDB cannot answer `contains` from
  a key.
- Any string field of a `@schema type state`, not only `@displayName` ones.
- `@searchable` (one GSI per field), `@searchable("group")` (fields share one GSI
  with a composite sort key), `@searchable(indexed=false)` (listed in
  `searchableFields`, no GSI, still a Scan).
- Pieces: `Searchable.res` in `reventless/spec/src/components/`, a ppx pass
  emitting entries into the same `indexConfig` that `@index` uses,
  `Plugin_Structure.labelFieldsFromStateSchema` sourcing `searchableFields` from
  it, and the list resolvers (local, AppSync, and the Postgres path in
  `PgQueryResolver_Lambda.res`) routing `searchPrefix` through the index when one
  matches.
- Document DynamoDB's 20-GSI-per-table cap where the annotation is documented.

## Open before starting

- The constant-partition GSI the parent proposed puts every row in one partition;
  measure whether that is acceptable or a bucketed partition is needed.
- `searchPrefix` is case-sensitive on DynamoDB while the in-memory backend is
  not. An indexed path keeps that gap unless it indexes a lowercased projected
  column — decide which.

## Not in this note

External full-text search (substring, case-insensitive, typo-tolerant), which the
parent called Phase 6.1 and deferred to a separate annotation backed by a search
service. Start that only when a real view needs it.

## Done looks like

A view declaring `@searchable` deploys a GSI, `searchPrefix` on that field reads
through it on every backend (no Scan for that predicate), and an unannotated view
behaves exactly as today.
