# Plan: `@retired` marks the state, not the field that holds it

**Status.** **DONE 2026-08-17.** Both changes are in the tree and released, the
examples use the constructor form (`Products` declares `Listed | @retired
Archived | @retired Discontinued`), and the browser acceptance this was waiting
on has now been run against a seeded local store.

**What the run showed.** A seeded store holds one product in each of the three
shelf states. `Products` badges the archived row **Archived** and the
discontinued one **Discontinued**, each by its own state name. `Unarchive Product`
is offered on the archived row **and on nothing else** — the listed row offers
`Archive Product` instead, and the discontinued row offers no shelf command at
all. The lifecycle page draws all three states, `Archived` keeping its outgoing
`Unarchive Product → Listed` and `Discontinued` rendered as an **END** card
reading "No commands available". `Customers`, a single-state retirement, renders
"Deactivated" exactly as an ordinary badge.

The narrowing was checked as a permission rather than a rendering choice, which
is the half a screenshot cannot show: an elevated caller widens to 20 rows with
`includeRetired`, while `merch` and `shopper` stay at 18 **even when they ask
for it**.

**One bug found on the same run, and it is not this plan's.** A discontinued
product can still be ordered — `PlaceOrder` never folds `CatalogProductWithdrawn`.
Filed as `Backlog/place-order-ignores-product-withdrawal.md`; it is a fold that
was never taught the event, not a retirement question.

**Goal.**

1. **`@retired` moves onto the constructor it names.** `| @retired Archived`
   rather than `@retired(Archived)` on the field. The fact "this state means
   withdrawn" belongs to the state, not to a slot that happens to hold it.
2. **A lifecycle may declare more than one retired state.** `Archived` and
   `Discontinued` both withdraw a product; `Deactivated` and `Closed` both
   withdraw a customer, by different routes and with different ways back.

---

## Why — the current form has a verified hole

`@retired(Archived)` takes a constructor *expression*, reads its leaf name, and
then **strips the attribute**. A stripped attribute never reaches the
typechecker, and `check_retired_field_type` verifies only that the field is not a
`bool` — it holds `ld.pld_type`, a reference to the enum, never that enum's list
of constructors. So nothing checks that the name exists.

Verified rather than reasoned: annotating the shipped `Categories` view with a
deliberate typo —

```rescript
@retired(Archivd) @lifecycle shelfStatus: shelfStatus,
```

— **compiles clean**, and `"Archivd"` lands in the emitted schema. Every row is
then compared against a state nothing is ever in, so **every row stays visible to
every caller**, while the annotation sits on the schema looking like enforcement.

That is verbatim the failure the annotation's own error text is written to
prevent: *"a row visible to everyone that looks as though it were restricted."*
The current form has an unguarded path into it, and no test can close it, because
the mistake is a well-formed string.

On the constructor the name cannot be wrong, because it **is** the declaration.
Removing the reference removes the class of bug rather than guarding it.

**Multiplicity depends on this.** A set of stringly-typed state names is the same
hole N times over, and harder to spot: one wrong entry in a list of three still
narrows *something*, so the symptom is a subset of rows leaking rather than all of
them. Do the move first, or not at all.

---

## Non-goals

**Not dropping the field form.** Two cases the constructor cannot serve, and both
are ordinary:

- **The boolean form.** `@retired deactivated: bool` has no constructor.
- **An enum declared elsewhere.** The PPX is per-file, so a shared or imported
  status type cannot be annotated from the spec that uses it.

The resulting shape is the one `@lifecycle` already settled on: the natural form
preferred, the explicit annotation kept for where it cannot reach. The same
argument, one level down.

**Not a second retired _field_.** `stateAnnotationSpec` documents why at most one
per record: *"two retirement flags are not a stricter rule but an unanswered one —
the read predicate would have to guess whether they conjoin or disjoin."* That is
right and unchanged. It is an argument about two **fields**, and says nothing
about two **states on one field**, which is unambiguous: retired iff the value is
in the set. One field, one predicate, membership instead of equality.

**Not a change to who sees a retired row.** Still `OwnerScope.elevatedGroups`,
still one deployment-wide answer.

---

## Shape

```rescript
@schema
type shelfStatus =
  | Listed
  | @retired Archived
  | @retired Discontinued

@schema
type state = {
  categoryId: string,
  @lifecycle shelfStatus: shelfStatus,   // no @retired here
}
```

Constructor attributes are the established mechanism in this PPX, not an
invention — `AllowedStatesAnnotation`, `NoApiAnnotation` and
`AuthorizationInjection` all read `pcd_attributes`, and `| @noApi ReopenOrder(…)`
is the same shape an author already writes.

The field form stays legal and unchanged:

```rescript
@retired deactivated: bool                    // boolean form
@retired(Deactivated) accountStatus: status   // imported enum, cannot be annotated
```

**Both forms on one field is an error**, not a merge. Two places to look for one
answer is how they drift.

---

## `option` is load-bearing — do not flatten it

`retiredSpec.value: option<string>` carries two facts, and only one of them is
the state name. `None` is the **form discriminator**: it is what distinguishes
the boolean form from the state form, and consumers match on it directly to
decide whether the field is a flag to hide or a lifecycle column to keep.

So the widening is `option<string>` → `option<array<string>>`, **not**
`array<string>`. A bare array makes `[]` mean both "boolean form" and "state form
naming no states", and the boolean form's handling silently stops firing on a
value that looks merely empty.

---

## Steps

### 1. PPX — read the constructor attribute

`StateAnnotations.ml` gains a pass over the `@schema` type declarations in the
file, collecting constructors that carry `@retired` (`pcd_attributes`, exactly as
`NoApiAnnotation` does), keyed by the type they belong to.

### 2. PPX — correlate the annotated enum to the field that holds it

The harder half, and the one to prototype first. The marker is on a type; the
schema entry is on a field. So a second pass over `@schema type state` matches
each field's type reference against the collected map, and the field that holds an
annotated enum becomes the retirement field.

Three errors worth raising by name rather than leaving to discovery:

- an annotated enum **no field holds** — the author annotated a state and got no
  enforcement, which is the silent-failure shape this plan exists to remove;
- **two fields** holding the same annotated enum — the "at most one per record"
  rule, reported at the second field;
- a field carrying **both** `@retired` and a type whose constructors carry it.

### 3. PPX — validate the field form against the enum it names

The field form survives, so its hole survives with it unless closed here. Where
the named enum is declared **in the same file**, check the constructor exists and
raise naming the near-miss. Where it is imported, the check is not available —
say so in the error text for the same-file case, so the gap is a documented limit
rather than an inconsistency.

### 4. Spec — `retiredSpec.values`

`value: option<string>` → `values: option<array<string>>`, per the discriminator
note above. Document it as a set: retired iff the field's value is in it, and a
single-element set is the ordinary case rather than a special one.

### 5. `SuryToJsonSchema` — emit the set

`x-reventless-retired` carries `values` in the state form, omitted entirely in
the boolean form, on the same omit-rather-than-write-empty rule `label` follows.

**Emit `value` alongside `values` for one release** when the set has exactly one
member. See Wire compatibility below.

### 6. Resolvers — membership rather than equality

`OwnerScope.decideRetired` / `retiredScopeOf` carry a set; every predicate that
compares one string becomes a membership test, in the same places the single-value
form is threaded today:

- `reventless/core/src/components/Api/QueryDbListQuery.res`
- `reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res` (both arms,
  plus the legacy branch)
- `reventless/local/src/adapter/QueryDb/QueryDbStorage_Sqlite.res` — the
  `json_extract` predicate, so the filter still lands **before** `LIMIT`
- `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` — the
  FilterExpression
- `reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res` and its
  `…/Runtime/PgQueryResolverEntryPoint_Ops.res`
- the single-entity resolvers

The `@owner` warning about pages shrinking applies unchanged and gets no worse: a
set predicate is the same access pattern as an equality one.

### 7. Publishers — withhold the payload of a row in any retired state

The three implementations that share no code move together, as before:
`LocalStateChangeDescriptor.res`, `StateTopic_AppSync_Ops.res`,
`StateTopicPublish.mjs`, with `StateChangeDescriptorParityTest` driving all three.
The rule is unchanged in words — omit `state` when the resulting row is retired —
and only the test broadens from equality to membership.

### 8. Examples

`Categories` and `Customers` move to the constructor form, keeping their single
retired state. Mechanical.

**`Products` gains the two-state lifecycle, and is the worked example.** It has no
lifecycle at all today — `Add`, and four `Change*` commands — so this is a
modelling addition rather than a rename:

```rescript
@schema
type shelfStatus =
  | Listed
  | @retired Archived
  | @retired Discontinued
```

It earns its place because the two states are not interchangeable, and the model
says so rather than a comment:

- **`Archived`** is reversible — a product withdrawn from the catalog that can
  come back. `@allowedStates([Archived])` on `UnarchiveProduct` offers the way
  back exactly where it exists.
- **`Discontinued`** is not. No command names it as a from-state, so the diagram
  draws it terminal and no surface offers a way out.

Both withdraw the row from ordinary reads identically — which is the point. One
predicate, one exclusion, two meanings the domain keeps apart. A boolean could
express the exclusion and nothing else; the second state is what carries "can this
come back", and `@allowedStates` reads it for free.

What it costs, and none of it is incidental:

- three events — `ProductArchived`, `ProductUnarchived`, `ProductDiscontinued`
- three StateChangeSlice commands, with `@allowedStates` as above
- `Products_Projection` folding them onto `shelfStatus`
- a refreshed `domain-api.graphql` golden, in the same commit

**The cross-plugin consequence, which is a decision and not a detail.**
`Products_ExtensionPointMapping` publishes `ProductBecameAvailable` and
`ProductPriceChanged`, and Ordering's `AvailableProducts` consumes
`CatalogProductSynced` / `CatalogProductPriceChanged`. Nothing carries a
withdrawal across the boundary — so a discontinued product **stays orderable in
the shop for ever**, and the retirement would be an operator-side fiction.

It is propagated, and step 9 is the whole of it — the extension point, both
extensions and `AvailableProducts`. A demo shop that keeps selling a discontinued
product teaches the wrong thing about the framework more loudly than the
retirement teaches the right one.

### 9. Carry the withdrawal across the plugin boundary

Five links, each of which currently knows only how a product *arrives*:

| # | File | Today | Gains |
|---|---|---|---|
| 1 | `catalog/src/ExtensionPoint/Products_ExtensionPointMapping.res` | maps `ProductAdded`, `ProductPriceChanged` | the withdrawal and the relist |
| 2 | `catalog-spec/src/Products_ExtensionPoint.res` | `ProductBecameAvailable`, `ProductPriceChanged` | `ProductWithdrawn`, `ProductRelisted` |
| 3 | `ordering/src/Extension/Products_Extension.res` | two `mapIncomingEvent` arms | two more |
| 4 | `ordering/src/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res` | `SyncNewProduct`, `ChangeSyncedPrice` | `WithdrawSyncedProduct`, `RelistSyncedProduct` |
| 5 | `ordering/…/AvailableProducts_Projection.res` | `Set`, `Update` | `Delete`, and `Set` again on relist |

**One withdrawal, not two.** `Archived` and `Discontinued` are the Catalog's
vocabulary; Ordering needs "orderable or not" and has no use for the difference.
`ProductWithdrawn({productId})` is the whole of what crosses. An extension point
that mirrored the catalog's lifecycle would make every future state of that
lifecycle a change to a published contract, which is the opposite of what the
boundary is for.

**Both new events carry only the id, and that is the design.** The relist is the
case that proves it. `ProductBecameAvailable` carries `name` and `price` because
Ordering had nothing when it arrived; on a relist Ordering already holds both —
`SyncCatalogProduct` exists to "maintain a local shadow of Catalog products inside
the Ordering DCB event log", and that shadow survives the read model's `Delete`.
So `RelistSyncedProduct({productId})` re-emits availability from state Ordering
owns, and Catalog is not asked to re-send facts the subscriber already has.

Re-publishing `ProductBecameAvailable` on relist is the tempting shortcut and is
worse: the EP mapping would have to source `name` and `price` from a
`ProductUnarchived` that has no reason to carry them, so the Catalog would end up
enriching an event to serve a subscriber's bookkeeping.

**`Delete`, not a flag.** `AvailableProducts` answers "what can I order", so a
withdrawn product leaves it. Marking it instead — `@retired` on the shopper view —
would look tidy and be wrong twice over: a shopper is not elevated, so the
narrowing would hide it correctly, but an operator *is*, and would find
discontinued stock in the shopper's catalog. It would also make Ordering restate a
lifecycle Catalog owns.

**Widening an extension point is a breaking change for an independently deployed
subscriber**, and this example only gets away with it because `catalog` and
`ordering` deploy together. A subscriber compiled against the old spec receives a
variant its `mapIncomingEvent` cannot decode. Say so where the events are added:
the next extension point to grow an event may have a subscriber that ships on its
own schedule, and the reader should meet the constraint here rather than discover
it there.

**GWT coverage per link**, since each is a mapping with no other test:
`Products_ExtensionPointMapping_GWT` (archive and discontinue both produce one
`ProductWithdrawn`; unarchive produces `ProductRelisted`), `SyncCatalogProduct_GWT`
(withdraw then relist restores name and price from the shadow), and the
`AvailableProducts` projection (`Delete` then `Set`).

### 10. Seeding

The example is only worth having if a seeded store shows it, and today's seed has
no product retirement to show: its one archive is a **category** (`cat-08`,
`archive: bool` on the category fixture).

- **`DemoData.res`** — product fixtures gain a retirement field, three-valued
  rather than the categories' bool, so a fixture states which shelf a product ends
  on. Default `Listed`; exactly one `Archived` and one `Discontinued` in every
  data set, `sample` included, so the smaller set exercises the same path.
- **Ordering.** Retire late in the catalog phase — after the products exist and
  after orders reference them — mirroring the reason already written against the
  archived category. A product withdrawn before anything points at it demonstrates
  nothing; withdrawn after, it shows an order still resolving a product the
  catalog no longer offers, which is the case the whole feature is for.
- **Reporting.** The catalog-edits line gains the two, e.g.
  `catalog edits: 2 repriced, …, 1 archived, 1 discontinued`.

**The seed cannot see its own enforcement, and should say so.** It authenticates
as `admin`, which is in `elevatedGroups`, so its verification queries return
retired rows and the view counts do **not** drop. That is correct and reads as
broken. Either assert the exclusion explicitly with a second, non-elevated read —
the honest option, and the one that would catch a regression — or state in the
summary that the counts are an elevated view. Silence here produces a bug report
against a working platform.

---

## Wire compatibility

**Enforcement is server-side, so wire lag is cosmetic, not a hole.** A consumer
reading only the old singular `value` loses a badge and a column decision; it does
not gain access to a retired row, because the resolvers already excluded it. Worth
stating plainly, because it is the difference between "an old client looks stale"
and "an old client sees what it must not".

Even so, emit `value` beside `values` while a set has one member, for one release,
so a pinned consumer degrades to nothing at all rather than to a missing badge.
Drop it once no consumer predating this can be reached — the same "it exists to
close a window, not to support two shapes" rule the lifecycle rename's shim used.

---

## Tests

- **PPX** — a constructor-annotated enum populates the spec; a typo in the
  *field* form is a compile error naming the near-miss (same file); an annotated
  enum no field holds errors; two fields holding it errors; both forms on one
  field errors.
- **`SuryToJsonSchemaTest`** — one retired state emits a one-element `values`
  (plus the transitional `value`); several emit all of them; the boolean form
  emits neither.
- **`OwnerScopeTest`** — `decideRetired` over a set, including the empty and
  single cases.
- **Query** — a row in *either* of two retired states is absent for a scoped
  caller and present for an elevated one, against both the push-down and the
  materialise-and-filter fallback, plus pagination.
- **`StateChangeDescriptorParityTest`** — a save into either retired state
  publishes `Updated` with no `state`; a save into a live state publishes it.
- **`Products` GWT** — `UnarchiveProduct` is accepted on an archived product and
  refused on a discontinued one. The framework half is `@allowedStates`, already
  covered; this asserts the *modelling* claim that makes the example worth having,
  so a later edit cannot quietly make `Discontinued` reversible.
- **Goldens** — `pnpm run check:graphql` green with `Catalog_Product.shelfStatus`,
  refreshed in the same commit.
- **The boundary, end to end** — discontinuing a product removes it from
  `AvailableProducts`; unarchiving one puts it back with its name and price
  intact, which is the assertion that pins the shadow as the source rather than a
  re-send from Catalog.

---

## Acceptance

- `| @retired Archived` needs no field annotation, and a field annotation is
  still accepted where the enum cannot be reached.
- A misspelled state in the field form is a compile error where the enum is
  local, and a documented limit where it is imported.
- A lifecycle may declare several retired states; a row in any of them is
  withheld from a caller who cannot widen, on every adapter.
- `values: None` still means the boolean form, and the boolean form's column
  handling is unchanged.
- One release emits both `value` and `values` for a single-state set.
- **The shop demonstrates it.** `Products` carries `Listed | Archived |
  Discontinued`; a seeded store holds at least one of each; `UnarchiveProduct` is
  offered on the archived one and on nothing else; and a discontinued product is
  no longer orderable, because the withdrawal crossed the extension point rather
  than stopping at the catalog.
- A seeded store's reported counts are either asserted against a non-elevated read
  or labelled as an elevated view — never silently the latter while looking like
  the former.
