# Plan: a retired row stops being listed, not being named

**Date:** 2026-08-17
**Status.** DONE 2026-08-17 — every step is in the tree, the whole matrix is
verified against the seeded local shop, and the consuming surface was accepted in
a browser on top of it (a shopper reads an archived product's name and its state
on their own order; an elevated caller opens the row the single-entity door used
to refuse everybody). The matrix: as a shopper, `Catalog_ProductsRefs`
names `prd-004` "Granite Workstation Studio / Archived" and `prd-008`
"…/Discontinued", while the list, the single-entity and the by-ids doors all
still refuse them; as an admin, the single and by-ids doors open with
`includeRetired: true` and refuse without it; and `Ordering_CustomersRefs` —
whose view did not opt in — answers a shopper nothing at all, deactivated rows
included, with the owner rule intact. Four things came out differently from the
plan below, each recorded at its step:

- **The door is emitted for every view, not only the opted-in ones** (decision 3).
  The plan said "a record without the opt-in gains nothing", and
  `deriveConnectionQueryField`'s own comment argues the opposite case
  convincingly: a field that appears and disappears with an annotation makes
  adding or removing it a breaking schema change, and forces clients to
  feature-detect. What the annotation decides is not whether the door exists but
  whether a *retired* row comes through it. This also settles the multi-backend
  question — one SDL serves all four, so a field without a resolver somewhere is
  a field that errors.
- **`namedWhenRetired` lives inside `retiredSpec`**, not beside it. The PPX
  refuses the annotation on a record with no retirement, so the nesting states a
  guarantee rather than a convention.
- **`retiredState` is null for a live row**, which the plan implied and the first
  implementation got wrong: it reported the row's current state for any state-form
  view, which would have published a lifecycle column to callers the list
  withholds. Caught in the browser-facing verification, not by a test.
- **A parity gap was found, not fixed** — see below.

**Found and deliberately not fixed: the DynamoDB backend never narrowed
retirement on the single-entity or by-ids doors.** `getItemById` and
`batchGetItemsByIds` apply owner scoping and no retirement predicate at all; only
`listAllItemsConnection` narrows. So on a DynamoDB deployment an archived row is
already readable in full by any caller who can name its id — which is what this
plan's own "Why" section assumes is closed. The local and Postgres backends do
narrow all four doors. Fixing it changes what deployed DynamoDB apps return and
belongs in its own change; the reference door added here narrows correctly on
that backend regardless, so nothing new is opened by this work.
**Closed 2026-08-17** by [done/dynamodb-narrows-every-door.md](dynamodb-narrows-every-door.md),
which narrowed all four DynamoDB doors and then applied `@owner` to the two that
never had it. One asymmetry outlived it — the by-index door narrowed retirement
with no way to ask past it — and closing that on 2026-08-18 found the door did not
answer on any backend at all, its SDL disagreeing with its resolver differently
per backend:
[done/index-door-cannot-be-widened-to-the-archive.md](index-door-cannot-be-widened-to-the-archive.md).
**Stack:** `reventless-ppx` (OCaml), `reventless/spec`, `reventless/core`
(codegen + schema emission), `reventless/local`, `reventless/aws`. No new deps.
**Relates to:** [done/retired-state-flag-annotation.md](retired-state-flag-annotation.md)
(the annotation and its enforcement), [done/retired-marks-the-state-not-the-field.md](retired-marks-the-state-not-the-field.md),
[done/retired-as-a-lifecycle-state.md](retired-as-a-lifecycle-state.md)
(the state form).

## Why

`@retired` withholds a row from every door at once — the list, `X(id:)`,
`XsByIds`, the index reads — and that is right for the question it was built to
answer, which is "what may this caller browse". It also answers a second question
it was never asked: "what is the row this caller is already holding a reference
to called".

Those come apart the moment one record references another. An order names three
products by id. Archive one, and the shopper reading their own order — a row they
own and the platform serves them in full — can no longer learn what they bought.
The reference resolves to nothing, and the surface reading it has a bare id where
a name was.

The withholding is doing exactly what it was written to do. `retiredAllows` on
the by-ids door is deliberate and its comment says so: that door is where a
filtered list would otherwise be walked around, "a reference resolved from another
row reaches the entity directly". Both readings of that sentence are true. It *is*
the walk-around for enumerating the archive, and it *is* the only way to name a
row you legitimately hold a pointer to.

So the rule needs to distinguish them, and only the domain can: whether the names
in an archive are public is a property of what is archived. An archived product's
name is on every order that bought one. A deactivated customer's name is not, and
a door that resolves it turns a guessed customer id into a name oracle.

**Goal.** Let a record declare that a reference to one of its retired rows still
resolves — to that row's identity and nothing else — and keep every other door
shut exactly as it is today.

**Non-goal — loosening the owner rule.** This lifts the retirement predicate and
only that. A retired row that is owner-scoped stays owner-scoped: the caller
resolves their own, or nothing. Two predicates, decided separately, and the one
this plan does not name is untouched in the code as well as in the prose.

**Non-goal — deciding who is elevated.** Unchanged from the annotation plan: the
`REVENTLESS_ELEVATED_GROUPS` mirror answers it, once. Elevation is not what this
door turns on — it answers *every* caller, which is the point, and is why the
projection is narrow rather than the audience.

---

## The rule

A retired row answers a **reference-resolving read** with three facts:

- its `id`,
- its `labelField` — the field a reference already resolves to, whose ladder
  (`@displayName` → convention → position → `"id"`) is `Plugin_Structure.labelFieldsFromStateSchema`,
- the state that retired it: the value of `retiredField`, so a consumer can say
  *which* retirement this is where a lifecycle has several.

It answers nothing else, and every other read is unchanged: it is absent from the
list, from the index reads, from `X(id:)`, from the ordinary by-ids door, and
from the live change frame's payload.

Opt-in per record. Absent the opt-in, today's behaviour holds everywhere.

---

## Three decisions

### 1. Where the opt-in is written

It has to be sayable in **both** forms of `@retired`, and the constructor form
takes no payload by design — "the state's own name is what a consumer renders, so
there is no label to state" ([StateAnnotations.ml](../../../packages/reventless-ppx/src/ppx/StateAnnotations.ml)).
That is the right rule and this must not bend it: the opt-in is not a property of
one state anyway. `Archived` and `Discontinued` do not get to disagree about
whether the product has a public name.

**`@namedWhenRetired`, on the `@schema type state` declaration** — no payload,
its presence being the opt-in, as `@retired`'s own constructor form is.

```rescript
@schema @namedWhenRetired
type state = {productId: string, name: string, shelfStatus: shelfStatus, …}
```

`@live(true | false)` already establishes this site and the whole machinery for
reading it — `extract_state_live` / `strip_live_attrs` / `check_live_placement`
in the PPX, flowing through `stateAnnotationSpec` to a top-level schema key. A
record-level fact belongs on the record's own declaration, and there is already a
path from there to every consumer.

**Riding `@displayName` was considered first and is wrong.** It looked right —
the label field is the one thing the door emits, so name the leak where the field
is named — until the annotation's actual shape settled it: `@displayName` is
**multi-field and composed**, several fields joined by a separator into one
projected `displayName` column ([DisplayNameInference.ml](../../../packages/reventless-ppx/src/ppx/DisplayNameInference.ml)).
A per-field opt-in on a composed label has to answer what
`@displayName(Public) firstName` beside a plain `@displayName lastName` means,
and every answer is bad: refuse it and the annotation carries a rule about its
siblings, honour either reading and half a name is public by typo. The property
is the record's — *this kind of row keeps its name* — so it goes on the record.

A file-level `@@reventless.namedWhenRetired` was the third candidate. Rejected
for the reason file-level attributes generally lose: a reader with the record on
screen has everything else about it in view, and this would be the one fact a
screen away.

### 2. Whether the row can be opened, and by whom

A resolved name invites a click, and today nothing is behind it: `includeRetired`
is emitted on the **connection field only**. Introspecting a running server:

```
Catalog_Products      -> [filter, orderBy, first, after, last, before, includeRetired]
Catalog_Product       -> [id]
Catalog_ProductsByIds -> [ids]
```

Since `decideRetired` withholds from `Elevated` and `System` too until they ask,
and the single door gives nobody a way to ask, **a retired row's single-entity
read is refused for every caller alive**. That is a defect in the shipped
feature, not a consequence of this one: an elevated caller who turns on the
archive toggle, sees an archived row in the list and clicks it, is reading a row
the platform will not serve one at a time. This plan should carry the fix,
because it is the same question — what remains reachable about a withdrawn row —
and because a reference door that resolves a name a caller can never open is half
a feature.

**`includeRetired` extends to the single-entity and by-ids doors**, with the
identical rule it already has on the list: honoured for a caller who was going to
be allowed the row, ignored (not refused) for one who was not. No new predicate,
no new audience — the same argument reaching two doors that were built to accept
it and were not given it.

Note the two mechanisms then answer different callers, deliberately: the
reference door names a row for *anyone* holding a pointer to it, and
`includeRetired` opens it in full for the elevated. Narrow-for-all and
full-for-some, and neither can be reached by the other's audience.

### 3. How the narrow read is distinguishable

If the opt-in simply exempted the row from `retiredAllows`, it would reopen the
whole record — the very walk-around the door was closed for.

**Recommended: a dedicated generated door.** Codegen emits, for opted-in records
only, a by-ids read whose *return type* is the projection:

```graphql
type Catalog_ProductRef { id: ID!, label: String!, retired: Boolean!, retiredState: String }
Catalog_ProductRefs(ids: [ID!]!): [Catalog_ProductRef!]!
```

The narrowness is then the schema's, checked by the GraphQL layer rather than by
a runtime rule each backend re-implements. `retiredAllows` — the security-critical
predicate — is not touched at all, in any adapter. `retiredState` is null in the
boolean form, where the field is the state and there is no name to send.

The alternative considered and not recommended: gate the *existing* by-ids door on
its selection set — answer a retired row when the caller asked only for the three
permitted fields. It needs no new schema surface, but it needs `info` plumbed into
`resolverFn` (today `(root, args, ctx)`) and its AppSync counterpart, and the
"permitted set" rule then has to survive aliases, fragments and `__typename` in
four backends. A projection that the type system enforces cannot be got wrong that
way.

---

## Steps

1. **PPX + spec.** Parse `@namedWhenRetired` off the `@schema type state`
   declaration, mirroring `@live`'s four functions; carry it on
   `stateAnnotationSpec` beside `retired`; error when the record declares no
   `@retired` (it would declare nothing) and when it sits on a spec file that is
   neither a ReadModel nor a StateViewSlice (`check_live_placement`'s rule,
   verbatim — an annotation that is silently dropped is worse than one that is
   refused). Emit it on the schema for consumers that read schemas rather than
   defs.
2. **`queryableDef`.** A flag beside `retiredField` / `retiredValues`, so a client
   holding the def knows the door exists without probing for it. The label field
   is already published there; do not send a second copy.
3. **Codegen.** Emit the `*Ref` type and the by-ids field for opted-in records
   only. A record without the opt-in gains nothing — no empty type, no field that
   always refuses.
4. **Resolvers, four backends** — local memory, local sqlite, DynamoDB/AppSync,
   Postgres lambda. Each already has a by-ids read; this is that read with the
   retirement predicate skipped, the owner predicate **kept**, and three fields
   projected. The projection happens at the source in each backend, not by
   deleting keys from a full row after reading it.
5. **`includeRetired` on the single-entity and by-ids doors** (decision 2) —
   codegen emits the argument, and each backend's `retiredAllows` reads it
   through the `askedForRetired` / `decideRetired` pair the list door already
   uses. Independent of steps 1–4 and shippable before them: it needs no
   annotation, and it turns an existing archive toggle from a list a caller
   cannot click into one they can.
6. **Live.** Unchanged, and say so in the plan's own record: the change frame's
   downgrade to metadata-only stays. This is a query-time affordance for a caller
   holding a reference, not a subscription one.
7. **Tests.** Per backend: an opted-in retired row resolves through the new door
   and stays absent from the list, `X(id:)`, the ordinary by-ids door and the
   index reads; a non-opted-in retired row resolves nowhere; an owner-scoped
   retired row resolves through the door **only for its owner**; a live row
   resolves as it always did. Plus the two PPX errors from step 1.
8. **Docs.** The `@retired` rule in [.claude/rules/app-developer.md](../../../.claude/rules/app-developer.md)
   gains the opt-in and its narrow projection; `ui-configuration.md` §2.11 gains
   the same beside `includeRetired`, which stays what it is — the elevated
   caller's way into the archive, not this.

## Acceptance

A record annotates its label field as public, archives a row, and a caller who is
neither elevated nor the archive's audience resolves that row's name and its
retiring state through the reference door — while the same caller, on the same
connection, finds it in no list and behind no other door. A record that does not
annotate behaves exactly as it does today, which the existing suites already
assert and must keep asserting unchanged.
