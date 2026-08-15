# Plan: `@retired` — a boolean field that withdraws its row from ordinary reads

**Status.** PLAN 2026-08-15. Framework capability: one new state-field annotation
with a presentation half (carried on the schema, consumed downstream) and an
enforcement half (applied in the query resolvers). The enforcement half is the
reason this cannot be a schema-only change like `@groupBy` was.

**Goal.** Let a state record declare that one of its booleans means *this row is
retired from ordinary use* — a deactivated customer, an archived category — and
have the platform, not each consumer, decide who still sees it. Two consequences
follow from the single annotation:

1. The flag is published on the field's JSON Schema so a consumer can render the
   row's retirement as a property of the row rather than as another data column.
2. Rows whose flag is true are withheld from callers that are not elevated,
   everywhere a row can be reached: list queries, single-entity queries, and the
   live change channel.

**Non-goal — deciding who is elevated.** That question is already answered, once,
deployment-wide, by `OwnerScope.elevatedGroups`. This plan reuses that answer and
introduces no second list. Per-annotation elevation is rejected for the reason
`OwnerScope` already documents: two views would disagree about who an operator
is, and the gap would appear one view at a time.

**Non-goal — per-subscriber live channels.** The state-change channel is keyed by
list field and entity, shared by every subscriber. Step 8 removes the *payload* of
a retired row from that channel but cannot remove the fact that an entity with
that id changed. Closing that residual would mean re-keying the channel per
caller, which is a larger change with its own analysis; it is out of scope and
recorded in Acceptance as a known limit.

---

## Shape

`@status` and `@groupBy` are the precedent for a single-field state annotation
carried through `stateAnnotationSpec`. `@owner` is the precedent for row-level
narrowing in the resolvers. This is the first annotation that is both, which is
why the steps split across the spec, the PPX, codegen, three resolver families
and three publishers.

Surface:

```rescript
@schema
type state = {
  @id customerId: string,
  displayName: string,
  @retired deactivated: bool,
}
```

```rescript
@retired({label: "Archived", showWhenFalse: true}) archived: bool
```

Bare form takes the label from the field name. The record form follows `@metric`,
which already accepts either a bare payload or a record of options.

**`@retired` neither implies nor wants `@scan`.** `@scan` widens the *client's*
filter surface — it puts `<field>Eq` on the `Filter` input for a field with no
backing index. Nothing here is a client filter: the predicate is the resolver's,
derived from who the caller is, and it is threaded as its own parameter exactly
the way `@owner` already is, beside `filterFields` rather than through it. `@owner`
is the proof — it narrows every read on every adapter and carries no `@scan`.

Adding one would publish `deactivatedEq` to callers who cannot use it: a scoped
caller passing it can only ever get an empty page, because the resolver excluded
those rows before the filter was consulted. The elevated caller's route to the
archive is `includeRetired` (step 7), and one door is enough.

---

## Release shape

**The annotation is the switch.** Nothing below is observable until some state
record writes `@retired`. No annotated field ⇒ `stateAnnotationSpec.retired` is
`None` ⇒ no `x-reventless-retired` on any schema ⇒ `queryableDef.retiredField` is
`None` ⇒ `retiredScopeOf` returns `None` for every caller ⇒ every resolver and
every publisher behaves exactly as it does today. So the whole chain can land
dark, and the first annotated field is what turns it on — which is the opposite
of the order these are usually built in, and is the point: the annotation lands
*after* every consumer of it is in place, not before.

**Steps 1–3 are one release and cannot be split.** `stateAnnotationSpec` is an
exact record and the PPX emits a full record literal for it, so new spec + old PPX
is a missing-field compile error at the generated binding, and new PPX + old spec
is an unknown-field one. They move together: spec change, PPX change, PPX
republished as its per-platform packages, lockfile pin moved to match, in the one
version bump.

That lockstep is the price of `retired: option<retiredSpec>` over
`retired?: retiredSpec`. The optional-field form would let an older PPX omit the
key and still compile, and is what the house convention prefers for new types.
It is deliberately not taken here: every sibling on this record (`status`,
`groupBy`, `visibility`, `live`) is written with `option<>`, and the PPX's own
comment records that the Some/None wrapper exists to avoid the `@res.optional`
AST gymnastics an optional field would require. Matching the record's established
shape is worth one coordinated bump of two packages that already release together.

**Steps 4–5** (`queryableDef` + codegen) may ride that release or the next one;
they are inert either way. Fold them in unless a smaller first bite is wanted.

**Steps 6–8** (classification, resolvers, publishers) change behaviour, but still
only for annotated fields — of which there are none until the switch is thrown.

The first annotated field belongs after the *consumers* of this capability are
ready, not after this repo is. What that requires is the consuming repo's to
state; this repo's part is that the capability is inert until then.

---

## Steps

### 1. `reventless/spec/src/components/StateAnnotations.res`

Add, as a sibling to `status` and `groupBy`:

```rescript
type retiredSpec = {field: string, label: string, showWhenFalse: bool}
```

and `retired: option<retiredSpec>` on `stateAnnotationSpec`. Document it in the
module's leading comment alongside the other field roles: it names the boolean
whose truth withdraws the row, `label` is what a consumer titles that state with
(empty ⇒ derive from the field name), and `showWhenFalse` asks a consumer to
surface the flag in its negative state too.

`option<retiredSpec>` rather than an array: at most one per record. Two retirement
flags do not make a stricter rule, they make an unanswered one — the read
predicate would have to guess whether they conjoin or disjoin, and the resolvers
below take a single field.

### 2. PPX — `packages/reventless-ppx/src/ppx/StateAnnotations.ml`

Parse `@retired` on `@schema type state` record fields.

- Payload parsing mirrors `get_metric_value`: absent payload ⇒ defaults; a record
  payload ⇒ read `label` and `showWhenFalse` via `find_record_str` and a bool
  sibling; anything else ⇒ `Location.raise_errorf` naming both accepted forms.
- **Type check.** Accept `bool` and `option<bool>` (and the `field?: bool`
  optional-field spelling, which reaches the PPX as `bool` plus `@res.optional`).
  Reject everything else with an error explaining that the annotation names a
  predicate the query layer evaluates — an `array` or `string` field would
  annotate a schema no read predicate can use, and would scope nothing while
  looking as though it did. Absent ⇒ read as false.
- **Duplicate check.** Mirror the `@status` / `@groupBy` handling exactly: two
  `@retired` in one record is a compile error at the second one's location.
- Strip the attribute from the field, and add it to `strip_*_attrs`.
- Emit into the spec record in `make_state_annotations_binding`. This needs a new
  AST builder for `option<retiredSpec>` — the inner record follows
  `metric_tuple_array`'s nested `Pexp_record`, the `Some`/`None` wrapper follows
  `status_value`. Add it to the all-empty early-return condition.

### 3. `reventless/core/src/components/Api/SuryToJsonSchema.res`

In `deriveObjectSchema`, beside the `x-reventless-hidden` / `x-reventless-summary`
/ `x-reventless-group-by` branches (~lines 56–63), emit on the named property:

```
x-reventless-retired: {label: "Archived", showWhenFalse: false}
```

Omit an empty `label` the way the `x-reventless-metric` branch already omits its
empty label, so a consumer deriving one from the field name can tell "not stated"
from "stated as empty".

### 4. `reventless/spec/src/components/Plugin.res`

Add `retiredField: @s.matches(stringOptionSchema) option<string>` to
`queryableDef`, documented as the resolvers' half of the annotation: the field a
non-elevated caller's reads are narrowed against. `js_nullable` for the same
JSON-safety reason as `statusField`. The *label* deliberately does not travel
here — it is on the schema, which every consumer of `queryableDef` already holds,
and a second copy is a second thing to keep in step.

### 5. `reventless/core/src/plugin/component/Plugin_Structure.res`

Populate it from the annotation spec, mirroring `statusFieldFromStateSchema`
(~line 53) but with no convention fallback — a boolean named `archived` that was
never annotated must not start hiding rows, so resolution is annotation-or-nothing.
Two call sites: the ReadModel branch (~line 764) and the StateViewSlice branch
(~line 799), beside the existing `statusField` / `ownerField` lines.

### 6. Caller classification — `reventless/spec/src/types/OwnerScope.res`

`resolve` already classifies a caller (`System | Elevated | Owned | Unidentified`)
independently of any annotation; `decide(~ownerField)` is what applies `@owner` to
that classification. Add the sibling:

```rescript
let decideRetired: (t, ~retiredField: option<string>) => retiredDecision
let retiredScopeOf: retiredDecision => option<(string, bool)>
```

returning `Some((field, true))` — "exclude rows where `field` is true" — for
`Owned` and `Unidentified`, and `None` for `System` and `Elevated`.

`Unidentified` filters rather than refuses: unlike `@owner`, there is no
caller-specific value to compare against, so the fail-closed action here is the
narrow read, not a refusal. It stays in the same module as the owner decision for
the reason the module's own comment gives — the read path and every other path
must agree about who is exempt, and that agreement is only checkable if the two
decisions are written side by side.

### 7. Resolver enforcement

`retiredScope` is threaded exactly where `ownerScope` already is, and the warning
already written into `QueryDbResolvers_GraphQL.res` applies verbatim: passing it
to the fallback alone scopes the exceptional path and leaves the push-down
returning everything, which is the worst place for the gap because the fallback
is what tests most easily exercise.

- **`reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`** — both
  arms of the connection resolver (`Bus.getQueryDbListPage` push-down and the
  `QueryDbListQuery.run` fallback), plus the legacy AppSync-style branch, whose
  narrowing is a plain `Array.filter` and needs the same predicate added.
- **`reventless/core/src/components/Api/QueryDbListQuery.res`** — the shared spec
  both local backends and the push-down are tested against.
- **`reventless/local/src/adapter/QueryDb/QueryDbStorage_Sqlite.res`** — the
  `json_extract` predicate builder, so the filter lands before `LIMIT`. Filtering
  after the limit yields short pages and a `hasNextPage` that describes a
  different result set than the one returned.
- **`reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`** — the
  FilterExpression path.
- **`reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res`** and
  **`.../Runtime/PgQueryResolverEntryPoint_Ops.res`**.
- **Single-entity resolvers.** A list filter that the get resolver does not honour
  is not a filter: a pasted URL, or a reference resolved from another row, walks
  straight around it. Return the null/refused shape for a retired row when
  `retiredScopeOf` is `Some`, mirroring how `RefuseOwned` short-circuits today.

**`includeRetired: Boolean` list argument.** Generated onto the list query SDL and
honoured **only** when `retiredScopeOf` returns `None` for this caller. A scoped
caller passing it is ignored rather than refused — a refusal reports that the
argument means something, and there is nothing to gain by saying so. Without this
argument an elevated caller can never reach the archive at all, so it ships with
this plan rather than after it.

**Cost, and what does and does not fix it.** The list-all field on DynamoDB is
already a Scan; the retirement predicate does not create one. What it buys is the
pathology `@owner` is already warned about in `QueryDbResolvers_AppSync.res`
(~line 247): a FilterExpression is applied *after* the page is read, so pages
shrink as the retired share of the table grows — correct, but pathological on a
table that is mostly archive.

The warning therefore fires on `@retired` **without `@index`**, and `@scan` does
not satisfy it. `@scan` adds no index and removes no read unit; letting it silence
the warning would make the warning dismissible by an annotation that changes
nothing. Word it as the `@owner` warning is worded, and for the same reason: it
warns rather than refuses, because a small table may legitimately accept the cost.

**Open — the index-shaped answer, undecided.** Three options, and the choice is
not obvious enough to make here:

1. `@index` on the flag. Simple, but a GSI keyed on a two-value boolean is a
   hot-partition antipattern: every live row lands in one partition.
2. A **sparse index over live rows** — an index key attribute present only while
   the row is live, so the scoped list becomes a Query rather than a
   Scan-and-filter. Idiomatic, and used deliberately already in
   `DcbEventLogStorage_DynamoDb_Runtime.res` (~line 122).

   **Checked, and it does not fall out of the annotation.** The QueryDb writer
   puts the projected state JSON wholesale (`saveBatch` /`putWithRetries`), so an
   attribute is present exactly when the encoded state carries it — and
   `deactivated: bool` carries it in *both* states. A boolean field can therefore
   never index sparsely. It needs a **derived** attribute, written when the row is
   live and omitted when it is retired.

   That is mechanically available: `Util_DynamoDb_Runtime.injectId`
   (`reventless/aws/src/util/Util_DynamoDb_Runtime.res:15`) already injects an
   attribute that is not part of the state record, on both write paths. A
   conditional `injectLiveMarker` is the same move. But it is framework-injected
   plumbing on the AWS writer plus a GSI in the table config — a real piece of
   work, not a annotation-level freebie, and it has no analogue to pay for on the
   in-memory and SQLite backends.
3. Accept the filter cost with the warning, as the `@owner` path does today.

**Decision: option 3 for this plan.** The list read already Scans, the predicate
adds no new access pattern, and `@owner` has lived with exactly this profile. The
degradation is proportional to the archived share, so it is fine until a table is
mostly archive — and the deploy-time warning is what says so out loud.

Option 1 is available to an author today and needs nothing from this plan. Option
2 is the answer when a table really is mostly archive; it is additive, changes no
surface, and is a follow-up plan rather than a step here.

### 8. Publisher — withhold the payload of a retired row

`state` on a change descriptor is advisory; a subscriber may always ignore it and
refetch. Retirement is where that has to be used: the channel is shared by every
subscriber, so a publish carrying the full row of a retired entity delivers, to
callers the resolvers just refused, the row they were refused.

The rule is **omit `state` when the resulting row is retired** — reusing the
metadata-only downgrade the descriptor already has for oversized payloads. Not
`Removed`, which is false for an elevated subscriber reading with
`includeRetired` and false again on un-retirement; and not scoped per subscriber,
which the channel cannot express. `Updated` with no payload asks every subscriber
to refetch, and each one's refetch is then answered by the resolvers above — one
implementation of the rule, consulted by everyone.

Note the asymmetry, which is deliberate: **un**-retiring publishes full state as
before, because the resulting row is not retired. Only the retiring direction
pays a refetch.

Three implementations share no code and must change together, with
`StateChangeDescriptorParityTest` (reventless-aws) extended to drive all three
and assert they agree:

- `reventless/local/src/adapter/LocalStateChangeDescriptor.res`
- `reventless/aws/src/adapter/StateTopic/StateTopic_AppSync_Ops.res`
- `reventless/aws/src/adapter/Runtime/StateTopicPublish.mjs`

Each needs the retired field name at publish time. It is derivable from the read
model's own annotation spec where the publisher holds the schema; where it does
not (the DynamoDB stream relay), it travels the same route the sort-key
configuration already does.

### 9. Tests

- `SuryToJsonSchemaTest` — an annotated field emits `x-reventless-retired` with
  label and flag; an unannotated one emits nothing; an empty label is omitted.
- PPX — spec populated from both payload forms; duplicate `@retired` errors;
  a non-boolean field errors; `option<bool>` and `field?: bool` both accepted.
- `OwnerScopeTest` — `decideRetired` across all four classifications, including
  `Unidentified` filtering rather than refusing.
- Query — a retired row is absent for a scoped caller and present for an elevated
  one, asserted against **both** the push-down and the materialise-and-filter
  fallback (the parity that step 7's warning is about), plus pagination: a page of
  N with retired rows interleaved returns N live rows, not N-minus-retired.
- Single-entity — a scoped caller asking for a retired row by id gets the refused
  shape.
- `includeRetired` — honoured for elevated, ignored for scoped.
- `StateChangeDescriptorParityTest` — a retiring save publishes `Updated` with no
  `state` in all three implementations; an un-retiring save publishes full state.

---

## Acceptance

- A `@retired`-annotated boolean emits `x-reventless-retired: {label, showWhenFalse}`
  on its property; duplicates and non-boolean fields are compile errors; a field
  with no `@index` warns about the read cost, and `@scan` does not silence that
  warning — it adds no index and removes no read unit.
- `@retired` does not require, imply, or interact with `@scan`: the predicate is
  the resolver's, threaded as its own parameter beside `ownerScope`, and the field
  gains no `<field>Eq` on the `Filter` input.
- `queryableDef.retiredField` is populated from the annotation only, never from a
  conventionally-named boolean.
- A caller not in `elevatedGroups` cannot reach a retired row through the list
  query, through the single-entity query, or through a change-descriptor payload.
  An elevated caller reaches them by passing `includeRetired`.
- Pagination is correct in both directions: the predicate is applied before the
  limit on every adapter.
- **Known limit, accepted:** a scoped subscriber still learns that *an entity with
  a given id changed*, because the channel is shared and the descriptor carries
  its `id`. This takes disclosure from the whole row down to the existence of an
  id. Removing that residual requires per-caller channels and is not in scope.
