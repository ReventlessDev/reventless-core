# Plan: the field a read model is named by

**Date:** 2026-07-29
**Status:** IMPLEMENTED (2026-07-29) — all four phases landed; verified against a
live `online-shop-hybrid` local platform. The one leg not run is a browser walk
of the rendered heading (see Verification).

## Motivation

Every read model publishes a `labelField` — the field that names one of its
records. It is what a reference dropdown lists, what a detail heading shows,
what `QueryDbListQuery` matches `search` / `searchPrefix` against, and what
`Api_Naming.queryNames` carries into every generated query. One function
decides it for all four
([Plugin_Structure.res:47](../../reventless/core/src/plugin/component/Plugin_Structure.res)),
and its ladder is:

1. `@displayName` spec present → `"displayName"` + the spec's source fields.
2. Otherwise: the **first** field, in declaration order, that is not `TAG`, is
   not named `id`/`*Id`/`*Ids`, and whose sury schema matches `String(_)`.
3. Otherwise `"id"`, with a warning.

Rung 2 is a three-line guess about what a field *is*, and this repo already has
the answer to that question:
[`SchemaType.fromSury`](../../reventless/core/src/components/Api/SchemaType.res)
is the IR every other schema consumer reads — it distinguishes `ScalarString`
from `DateTime`, `EntityId`, `Enum`, `Nullable(_)` and `Semantic(_, _)`, and it
derives the entity-id case from DCB tags and `Reference.getTarget` rather than
from a name suffix. Rung 2 reproduces none of that. So two readers of the same
schema disagree about the same field, and the label picker is the one that is
wrong.

### Measured, on the shipped example platforms

Running `labelFieldsFromStateSchema` over every spec module under `examples/`
alongside `SchemaType.fromSuryObject` of the same schema:

| View | Declared today | The IR's answer for that field |
|---|---|---|
| `Ordering.Orders` (online-shop-hybrid) | `placedAt`, `searchableFields: ["placedAt"]` | `DateTime` |
| `Ordering.Orders` (online-shop-aggregates) | `id` + warning | — no string field |
| `Ordering.Orders` (online-shop-dcb) | `id` + warning | — no string field |
| `Ordering.Customers` (online-shop-dcb) | `email` | `ScalarString` — correct shape, positional pick |
| `Catalog.Products` (online-shop-hybrid) | `name` | `imageUrl` is `Semantic(storageRef, ScalarString)` |

The first three rows are the finding. The same entity, modelled three ways,
declares two different labels — and the difference is not the domain. The
hybrid `Orders` state added

```rescript
placedAt: @s.matches(Reventless.DateTime.string) string,
```

so the date views would have a field to key off, and adding it **renamed the
entity**: a positional rule has no way to distinguish "the first string field"
from "the first string field that a human would recognise a record by", so the
new field silently took the name. Every order now presents itself as a raw ISO
timestamp, and the search box over orders matches substrings of
`2026-07-12T10:33:00.000Z`. `Catalog.Products` shows the same rule aimed at a
storage key: `imageUrl` is a bucket reference and matches `String(_)`, and the
only reason it is not the product's name is that `name` happens to be declared
before it.

### Latent, and of the same class

Not reachable on the current examples, but the rule admits all of them:

- **An optional string is invisible.** sury renders `option<string>` as a
  `Union`, so `String(_)` does not match it. A state whose only human field is
  `name: option<string>` declares `"id"` and warns that it has no suitable
  string field, while `SchemaType` reads it as `Nullable(ScalarString)`. This is
  the wrapper-blindness that `SchemaType` was given a `Union` branch for.
- **A reference is picked as a name.** `isIdLikeFieldName` tests the name; the
  IR tests the schema. A field carrying `Reference.to(…)`, or a DCB
  `@partitionTag`, and named `customer` rather than `customerId` is an
  `EntityId` to every other consumer and a label here.
- **The suffix test is case-sensitive.** `String.endsWith("Id")` misses
  `productID`; `SchemaType.isIdFieldName` lowercases first.
- **A semantic-carrying string is picked as a name.** `Semantic(storageRef, _)`
  — measured above on `Products.imageUrl` — is a string that names a stored
  object, not a record.

## Scope

| In | Out |
|---|---|
| Rung 2 of `labelFieldsFromStateSchema` reads `SchemaType` instead of matching sury shapes itself | The `@displayName` rung (rung 1) — unchanged |
| A conventional-name rung between 1 and 2 (`name` / `title` / `label` / `displayName`) | Any name-based *exclusion* list (`email`, `url`, `phone` — see Deferred) |
| `searchableFields`, which is derived from the same pick and moves with it | The `search` / `searchPrefix` semantics in `QueryDbListQuery` — it keeps matching whatever field is declared |
| `statusFieldFromStateSchema`'s convention rung reading the IR too, for the same reason | Emitting a per-field "is this a label" annotation — `@displayName` is that annotation |
| Fixtures + tests pinning each consequence above | Changing any example's domain model to acquire a better label (see Deferred) |

## Design decisions

1. **Read the IR, do not re-derive it.** The fix is not a longer list of
   exclusions in `Plugin_Structure`; it is deleting the shape test and asking
   `SchemaType.fromSury`, which is what `SuryToJsonSchema`,
   `GraphQL_FragmentGenerator` and the resolvers already ask. A second opinion
   about what a field is, is the defect — every exclusion added here would be
   one the IR already encodes, drifting on its own schedule.

2. **`Nullable(ScalarString)` is a label; `Semantic(_, ScalarString)` is not.**
   An optional name is still the entity's name — absent for some rows, which is
   a rendering question, not a declaration one. A semantic-carrying string is a
   value with a declared *meaning* (a storage ref, a URL), and the declaration
   is the schema saying it is something other than prose. Unwrapping `Nullable`
   and refusing `Semantic` is the whole shape rule:

   ```
   ScalarString      → label candidate
   Nullable(inner)   → whatever inner is
   everything else   → not a candidate
   ```

   `DateTime` and `EntityId` fall out of "everything else" without being named,
   which is the point of reading an IR: the next shape it grows is handled
   before it exists.

3. **`id` stays excluded by name, because the IR does not exclude it.**
   `SchemaType.isIdFieldName` requires `len > 2`, so a field literally named
   `id` is `ScalarString`. The existing `name == "id"` test stays; the `*Id` /
   `*Ids` half of `isIdLikeFieldName` is what the IR replaces.

4. **A conventional name outranks declaration order.** With rung 2 corrected,
   `Orders` falls to `"id"` — the honest answer for a state with no human field
   — but every state that *does* have one still picks it positionally, so
   `{sku, name}` names its products by SKU. A field named exactly `name`,
   `title`, `label` or `displayName` (case-insensitively) is the author saying
   which field that is, in the only way available short of the annotation. It
   goes *above* declaration order and *below* `@displayName`, which is explicit.
   It is an exact-name test, not a suffix one: `customerName` holds a customer's
   name, not this record's, and the existing `OrdersView` fixture depends on it
   being picked by position rather than by convention.

5. **`Orders` falling to `"id"` is the deliverable, not a regression.** The
   consumers of a `labelField` of `"id"` are already built for it: the
   `"no @displayName annotation and no suitable string field"` warning fires,
   and generated UIs warn a second time that dropdown labels will render as raw
   ids. That is a state with no human-readable field telling the truth about
   itself. A timestamp is the same absence, silently. Search moves with it, to
   substrings of the order id — which is a string a user can be looking at.

6. **`statusFieldFromStateSchema` rides along.** Its convention rung takes any
   field literally named `status` regardless of shape, so a free-text `status:
   string` is published as the lifecycle field that command menus are filtered
   against. Same class, same file, three lines: the convention rung requires the
   IR to say `Enum(_, _)` (or `Nullable(Enum(_, _))`). The `@status` rung is
   untouched — an annotation is a declaration, and it already rides outside the
   optional wrapper.

## Phases

### Phase 1 — the shape rule

In `Plugin_Structure.res`:

- Add `isLabelShape: SchemaType.schemaType => bool` per decision 2, and
  `isStatusShape` per decision 6.
- Rung 2 becomes: first item where `location != "TAG"`, `location != "id"`, and
  `SchemaType.fromSury(~parentName=entityName, ~fieldName=location, schema)`
  satisfies `isLabelShape`.
- Delete `isIdLikeFieldName`'s suffix half; keep the `id` test inline
  (decision 3). Update the ladder comment at the top of the file, which
  currently documents the rule being replaced.

### Phase 2 — the conventional-name rung

- `conventionalLabelNames = ["name", "title", "label", "displayname"]`, matched
  against the lowercased field name over the *eligible* candidates from
  Phase 1, before falling back to the first of them.

### Phase 3 — `statusFieldFromStateSchema`

- Convention rung requires `isStatusShape` (decision 6).

### Phase 4 — fixtures and tests

`PluginStructureTest.res` has a `labelField / searchableFields` describe block
with three cases; the existing two positional ones must keep passing unchanged
(decision 4). New fixtures under `tests/plugin/StateViewSlice/`, each pinning
one row of the tables above:

- a state whose only string is a `DateTime` → `("id", [])` + warning
  (the `Orders` case);
- a state with `{someId, placedAt: DateTime, name}` → `name`, proving the
  timestamp is skipped rather than the whole state refused;
- a state with `name: option<string>` → `name` (the optional case);
- a state with `{sku, name}` → `name` (the conventional rung, decision 4);
- a state with a `Reference`-carrying string not named `*Id` → skipped;
- a state with a `productID` → skipped;
- a `Semantic`-carrying string (`storageRef`) → skipped;
- a free-text `status: string` → `statusField: None`, and an enum `status` →
  `Some("status")`.

## Verification

- **`pnpm test`: 2280 tests / 276 suites green.** 20 new cases in
  `PluginStructureTest.res`, one per row of the tables above; the three
  pre-existing `labelField / searchableFields` cases pass untouched, which is
  what says the conventional rung did not quietly reorder the positional one.
- **Re-measured over every spec module under `examples/` plus the platform's own
  `Plugins` read model.** `Ordering.Orders` (hybrid) now reports `("id", [])`
  and warns, matching its two siblings; every other view — including
  `Customers`' `@displayName` path and the `email` positional pick in
  online-shop-dcb — reports exactly what it reported before.
- **Live, against the seeded `online-shop-hybrid` local platform** (150 orders):
  - the warning fires at plugin registration —
    `Orders: no @displayName annotation and no suitable string field —
    labelField falls back to "id"`;
  - `Platform_ComponentDefinitions` carries the new field, and a consumer
    reading it warns in turn that `Ordering.Orders` will render raw ids;
  - **search is the behaviour that actually moved.** `search` and
    `searchPrefix` match the label field, so they were matching substrings of
    an ISO timestamp. Over the same SQLite-backed list, `searchPrefix: "ord-00"`
    now returns `ord-001…003` and `search: "ord-01"` returns `ord-010…012`,
    while `search: "2026"` — which previously matched every order — returns
    nothing. The push-down reproduces it without a change, because it is passed
    the same declared field.
- **Not run: a browser walk** of the detail heading and reference cells. The
  path is `AutoDrillDetail`'s existing "labelField, when present on the row data
  as a non-empty string" rung and nothing about it changed — only which field it
  is handed. Stated here rather than implied.

### What the live run found

`Ordering.Orders` still reports **no label role** to a consumer's own
inference — the same line an earlier report recorded. The cause changed
underneath it: before, the server declared a timestamp and the consumer refused
it for carrying a date semantic; now the server declares that this entity has no
human-readable field, which is true, and says so twice — in its own log and in
the consumer's. The two answers per entity that motivated this (a heading
showing `2026-07-12T10:33:00.000Z` while every mode showed the row id) have
converged on the row id, and the disagreement is gone by being *resolved* rather
than by one side winning.

## Deferred

- **A name-based exclusion list** (`email`, `url`, `phone`). `Customers` in
  online-shop-dcb declares `email` as its label by position, and an email *is* a
  name a user recognises a customer by — so the exclusion would have to be a
  preference, and preference is what `@displayName` already expresses. Revisit
  only with a case where the positional pick is worse than `id`.
- **Giving the example `Orders` states a real label.** They have no
  human-readable field; inventing one to silence a warning would hide the thing
  this plan makes visible. An app that wants order numbers should model them.
- **Publishing *why* a label was chosen.** `queryableDef` carries the field but
  not the rung it came from, so a consumer cannot tell an explicit
  `@displayName` from a positional guess — which is the reason a consumer would
  reasonably rank its own heuristic above the declaration. A `labelFieldSource`
  on the def would settle that, and it is additive; it needs a consumer asking
  for it first.
