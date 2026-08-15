# Plan: `@status` → `@lifecycle`, annotation and wire

**Status.** PLAN 2026-08-15. A rename, end to end: the annotation authors write,
the spec field it fills, the name it is published under — **and the field name the
convention matches**, which is the one place behaviour changes and the one place
this repo's own records have to move with it.

**Goal.** `@status` names the field a record's lifecycle lives in — the enum a
command's `@allowedStates` is written in terms of, the one a board draws its
columns from, a progress tracker walks, and a state diagram renders. Everything
that consumes it already says *lifecycle*: the consuming pipeline's state-machine
page renders "No lifecycles" as its empty state, and the sibling annotations are
`@allowedStates` and `@targetState` — **states**, not statuses. The annotation is
the only member of its own family still called something else.

**Why it is worth a rename rather than a doc fix.** The name has already caused a
miscategorisation in the shipped example. `Customers` spends its one `@status` on
`locationStatus` — the geocoder's progress, `Pending | Located | Unresolvable` —
which no command branches on and no lifecycle passes through. It got the
annotation because the field's *name* matched the annotation's name. An
annotation meaning "commands branch on this" should not be selectable by string
similarity to the field it lands on; `@lifecycle(locationStatus)` would have made
the author ask the question and answer it correctly.

**Why `@lifecycle` and not `@state`.** Every spec file already declares
`type state` for the record itself, so `@state` would collide with the most
common identifier in the codebase.

**Non-goal — behaviour, with one deliberate exception.** Nothing new is published
and no consumer gains or loses a capability. The exception is the conventional
rung: it moves from a field named `status` to one named `lifecycle`, so an
unannotated `status` field that resolves today resolves to `None` after. That is a
real behaviour change, called out here rather than discovered — it is the same
decision as refusing a `@status` alias, applied to the other rung. Every site in
this repo that relies on it is enumerated in step 4 and fixed in the same change.
Outside those, a diff is a mistake.

**Non-goal — a compatibility alias.** No `@status` deprecation window: alpha, no
external users, and a silently-accepted old name is exactly the ambiguity this
removes. The old attribute becomes a compile error naming the new one.

---

## What has to move, and what must not

Three names, and they are not the same decision:

| name | where | rename |
|---|---|---|
| `@status` attribute | authored state records | → `@lifecycle` |
| `stateAnnotationSpec.status` | the PPX-collected spec | → `.lifecycle` |
| `queryableDef.statusField` | published on every read side | → `lifecycleField` |

**The conventional rung is renamed too, not merely re-documented.** Today an
unannotated field literally named `status` with an enum shape is picked up as the
lifecycle. After this, the name it matches is `lifecycle`.

Both rungs survive — an author may **either** name the field `lifecycle` and write
no annotation, **or** annotate whatever the field is called. Two ways to say one
thing, which is the point: a record whose lifecycle field can honestly be called
`lifecycle` needs no ceremony, and one whose cannot still has a way to declare it.

Keeping the rung on `status` was the first instinct and is wrong, for the reason
this plan exists. `status` is a **promiscuous** name — this repo alone uses it for
geocoding progress, todo-queue progress, translation audit outcome and plugin
connection state. A convention keyed on it genuinely guesses, and guesses often.
`lifecycle` is a deliberate word nobody types by accident, so a convention keyed
on it barely guesses at all: it is close to a declaration written in the field
name. Renaming the rung makes it *more precise*, rather than trading precision for
symmetry.

It is also what refusing the `@status` alias already implies. "A silently-accepted
old name is exactly the ambiguity this removes" applies verbatim to a rung that
keeps answering to the old vocabulary.

**What must NOT be swept up:** a consumer may resolve a *second*, inferred status
field from its own semantic ladder — the field a card badges a row by — which is
a different question from "which enum do commands branch on". Only the declared
one is renamed here. A blind search-and-replace across a consuming repo would
conflate the two; the consuming plan says so explicitly.

---

## Steps

### 1. PPX — `StateAnnotations.ml`

Rename the attribute. The duplicate check, the error text and the emitted
metadata key all move with it. An `@status` attribute becomes a
`Location.raise_errorf` naming `@lifecycle` — the rename should be discoverable
by compiling, not by reading a changelog.

### 2. Spec — `stateAnnotationSpec.status` → `.lifecycle`

Plus its doc block, which currently describes the field in terms of
`queryableDef.statusField` and the `"status"` convention. Both sentences need
rewriting rather than renaming.

### 3. Core — `queryableDef.statusField` → `lifecycleField`

`statusFieldFromStateSchema` → `lifecycleFieldFromStateSchema`, and the two
`Plugin_Structure` sites that fill it. The ladder keeps its shape and changes the
name it matches:

1. field annotated `@lifecycle`
2. field literally named `lifecycle` whose IR shape is an enum — was `"status"`
3. `None`

One string in the `Array.find` (`item.location == "status"`), and the leading
comment above it, which states the ladder.

### 4. Framework-generated queryables — annotate, do **not** rename

The convention is load-bearing inside this repo, which is what makes step 3 a
behaviour change rather than a string swap. Five state records declare an
unannotated enum field named `status` and resolve their lifecycle entirely by the
rung being moved. Each is visible in the committed SDL goldens:

| record | golden |
|---|---|
| `PluginsReadModelSpec` — two `type state` records | `Platform_Plugin.status` |
| AutomationSlice todo rows | `Ordering_AutoShipOrderTodo.status` |
| OutboundTranslationSlice todo rows | `Ordering_SendOrderConfirmationTodo.status`, `Ordering_GeocodeCustomerAddressTodo.status` |
| InboundTranslationSlice audit rows | `Catalog_ImportProductAudit.status` |

Left alone, every one of them silently loses its lifecycle on the day step 3
lands — command-menu filtering, board columns, group sections and state diagrams
go quiet for the platform's own admin view and for every generated todo/audit
list, with nothing failing to compile.

**Annotate them (`@lifecycle status: status`); do not rename the field.** The
field name is a *published wire name* — it is `status` in the SDL, in stored
QueryDb rows and in any client selecting it. Renaming would move the contract,
break selecting clients and require re-projection, all to satisfy a convention
that exists for authors' convenience. Annotating costs one word, keeps the goldens
byte-identical, and leaves these rows resolving by declaration rather than by a
guess — which is the better state of affairs regardless of this plan.

That asymmetry is the rule worth extracting: **the convention is for authored
records; framework-generated rows declare.** A generated row's field name is
chosen by the framework and read by everyone, so it is the wrong thing to make
load-bearing.

### 5. Admin API — the published name

`lifecycleField: String` on `Platform_ReadSideDef` in the SDL string, and the
matching encoder entry. Nullable, exactly as before.

### 6. **The read-path shim** — the one step that is not a rename

A persisted plugin structure is content-addressed in the offload store and read
back by the serving path as raw JSON. Those blobs carry `"statusField"` — this is
verifiable rather than assumed:

```
.readModels[0].statusField      = 'locationStatus'
.stateViewSlices[1].statusField = 'status'
```

Until each plugin re-registers, the serving path finds no `lifecycleField` and
answers `null`. That is not a crash — the SDL field is a nullable `String`, not a
`[T!]!` that would null-propagate to the root and answer the whole query with
`data: null` — but it is a silent degradation: command-menu filtering, board
columns, group sections, progress trackers and state diagrams all go quiet while
lists keep rendering.

So the resolvers read `lifecycleField`, falling back to `statusField` when
absent — the same healing both admin resolvers already do for absent required
lists. **Delete it a release later**, once no structure predating the rename can
be reached; it exists to close a window, not to support two names.

### 7. Examples — adopt the convention, and let them demonstrate both rungs

Four authored `@status` sites across the three examples, and they do **not** all
move the same way. That is deliberate: between them they are the worked example of
why both rungs exist.

**The three `Orders` views** (hybrid, aggregates, dcb) each declare
`@status status: status`. Rename the type and the field to `lifecycle` and **drop
the annotation** — the field name now carries it:

```rescript
@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type state = {
  ...
  lifecycle: lifecycle,        // no annotation — the name is the declaration
}
```

Constructor references are unaffected: `@allowedStates([Orders.Placed])` and
`@targetState(Orders.Shipped)` name variants, not the type.

**`Customers` keeps an explicit annotation** — `@lifecycle locationStatus:
locationStatus`. It cannot follow the convention, because the field is honestly
called `locationStatus` and calling it `lifecycle` would assert something false
about it. This is the case that proves the annotation rung has to survive, and it
is worth a comment in the file saying so.

The miscategorisation stays where it is already asked. Geocoding progress is not a
lifecycle, but correcting that is a modelling change with its own consequences and
belongs to `retired-as-a-lifecycle-state.md`. This plan renames it as-is.

**This step moves the GraphQL contract**, and is the only step that does.
`Ordering_Order.status: Ordering_OrderStatus!` becomes
`lifecycle: Ordering_OrderLifecycle!` in `examples/online-shop-hybrid/schema/domain-api.graphql`
and its siblings. Refresh the goldens in this commit — the schema diff is the
review artifact for a field rename, and a golden refreshed later is a diff nobody
reads. `pnpm run check:graphql` is the gate.

Consumers selecting `status` on an Orders query move with it. Nothing in this repo
does outside the goldens; a consuming repo's own plan owns its half.

### 8. Docs

The state-annotation reference, and anywhere the published field is named.

---

## Deployment order

The data is not the constraint; the query document is.

1. **Platform.** The SDL now declares `lifecycleField`; the shim means every
   already-registered plugin keeps working.
2. **Plugins re-register.** No wipe, no reset, and **no version bump**: the
   plugin definition carries its structure as a content-addressed reference, so a
   renamed key changes the hash, the aggregate's `Connect` sees a changed
   definition and re-emits `VersionConnected`, overwriting the stored def and
   re-projecting the row. `Redetect` is the deploy-time path that re-runs the
   handshake for an already-connected version.
3. **Consumers.** A consuming client must not go first: it selects the field by
   name, and GraphQL rejects a whole document that selects a field the SDL does
   not declare, so a client ahead of its platform boots to nothing rather than
   degrading.

Old offload blobs and historical `VersionConnected` payloads keep the old key
forever. Both are harmless — the blobs become unreferenced once the new hash is
stored, and the serving path reads the latest stored definition rather than
history.

## Tests

- **PPX** — `@lifecycle` parses onto the field; duplicates still error; `@status`
  is now an error naming the new attribute.
- **Structure** — `lifecycleField` is filled from the annotation and from a
  `lifecycle`-named enum field, and is `None` otherwise. **Add the negative
  case: an unannotated field named `status` now resolves to `None`.** It is the
  one behaviour this plan deliberately changes, so it is the one that has to be
  asserted rather than assumed — and it is what would otherwise be caught only by
  someone noticing a board had lost its columns.
- **Framework rows** — the Plugins read model and a generated todo/audit row
  still publish a `lifecycleField`, via their new annotations rather than the
  convention. Guards step 4 against being skipped, whose failure mode is silent.
- **Goldens** — `pnpm run check:graphql` is green with `Ordering_Order.lifecycle`
  in the domain schema and `Platform_Plugin.status` **unchanged**, which is the
  annotate-don't-rename rule stated as a diff.
- **Admin API** — the field appears in the SDL and round-trips; **and a structure
  carrying only the legacy key still answers with a value**, which is the shim's
  whole point and the one test that would otherwise be forgotten.

## Acceptance

- A plugin annotated `@lifecycle` publishes `lifecycleField`; every consumer
  behaves exactly as it did under `@status`.
- **A record whose field is named `lifecycle` publishes it with no annotation at
  all** — the convention rung, which is the half of this plan an author actually
  feels.
- An unannotated field named `status` publishes nothing. Deliberate, asserted, and
  the only behaviour this plan changes.
- No framework-generated queryable loses its lifecycle: the Plugins read model and
  the generated todo/audit rows declare theirs, and their published field names are
  untouched.
- A platform upgraded ahead of its plugins serves the legacy key through the shim
  with no visible change.
- `@status` no longer compiles.
- The three `Orders` examples carry no lifecycle annotation, and the domain schema
  golden moved with them in the same commit.
