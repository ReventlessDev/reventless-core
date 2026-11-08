# A decision that reads nothing

> **Status:** done 2026-11-08: unit suite, Postgres and DynamoDB integration suites pass.
>
> **Questions and short answers**
>
> - *What does a state-change slice read when its `consumedEvent` is `unit`?* **Nothing: it records
>   without a read and appends without a condition.** See [§2](#2-the-change).
> - *What does a query clause with an empty type list match?* **Nothing, in every store.** Today
>   the in-memory store matches nothing, while SQLite, Postgres and DynamoDB match every type that
>   carries the clause's tags. See [§1](#1-the-gap).

## 1. The gap

A state-change slice reads the events its `consumedEvent` names, under the command's tags, and
appends on condition that none of them changed since. Some decisions refuse nothing and keep no
state: they record each command as an event (a decision that notes what another system
published is one). Such a decision has nothing to read, and its natural spec is
`type consumedEvent = unit`.

`DcbDecode.makeDecoder` already gives an empty type list for that schema, and
`DcbTag.buildQueryFromCommand` passes it on as clauses with `eventTypes: Some([])`. The same
shape also arises when narrowing drops every type of a clause (a clause whose tags no consumed
type carries), which the query builder's documentation calls a clause that "matches nothing".
The stores disagree on it:

| Store | A clause with `eventTypes: Some([])` |
|---|---|
| In-memory, the test mock, the flow GWT | matches nothing |
| SQLite read and condition | matches every type with the tags |
| Postgres read (`DcbEventLogStorage_Postgres_Ops`) and condition (`dcb_condition_where`) | matches every type with the tags |
| DynamoDB read (`executeQueryItem`, `executeQueryItemStream`) | reads every type with the tags (a tagless clause scans every type) |
| DynamoDB condition (`appendConditional`) | its fence check skips it, but its tags still fence, and with no read position the folded create guard refuses a type the partition already holds |

So a decision with no consumed type reads, and fences on, the whole history of its tags on the
deployed stores, and reads nothing locally.

## 2. The change

- **`DcbTag.clauseMatchesNothing`** and **`DcbTag.readsNothing`**: a clause whose type list is
  empty matches nothing; a query of only such clauses reads nothing.
- **The state-change slice** reads nothing for such a query (no call to the store) and appends
  without a condition: what it did not read cannot have changed under it. A command with a
  stable id still reads its own produced types to drop a repeat, so its query is not empty.
- **Every store** matches nothing for a clause with an empty type list, in its read and its
  append condition: SQLite, Postgres (both the read and the SQL condition function), DynamoDB
  (both read paths, and its condition: such clauses are left out, and a condition of only such
  clauses appends unconditionally). The in-memory store, the mock and the flow GWT already do.

An empty query (no clauses at all) keeps its meaning, *everything*; only a clause's empty type
list changes.

## 3. Tests

- `readsNothing` holds for a query of empty-type clauses, not for an empty query.
- The in-memory and SQLite stores: a clause with an empty type list reads nothing, and as a condition
  never conflicts.
- A state-change slice with `consumedEvent = unit` records each command, issues no read, and
  appends without a condition.
- Postgres and DynamoDB: the same check in their integration suites
  (`PgDcbClauseMatchesNothing_IntegrationTest`, and a case in
  `DcbEventLogStorage_DynamoDb_IntegrationTest`). The DynamoDB case found the create guard above.

`DcbReadsNothingTest` (core) covers the slice and `readsNothing`; `DcbClauseMatchesNothingTest`
(local) covers the in-memory and SQLite stores. The whole unit suite passes (542 suites).
