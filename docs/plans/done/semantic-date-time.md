# Plan: `DateTime` as a semantic type, and `CalendarDate` beside it

**Date:** 2026-09-08
**Status:** Done, steps 1–5 and 7. Every fact below was read from the code rather than assumed; the
sury probes in D2/D3 were run against the pinned `sury@11.0.0-rc.2` and their output is quoted, and
re-run unchanged at build time. Step 6 (deleting `let string`) is deliberately left for the following
release. One thing the plan did not foresee — a ppx check that reads the literal `string` keyword —
is recorded as D7. `CalendarDate` shipped with **no adopter**, which is the form step 7 asks for and
what keeps the reader-first rule intact: nothing emits `format: "date"` until `reventless-ui`
separates the two semantics.
**Repos:** `reventless-core`. Step 3 changes a value the UI reads deliberately, but not a value it
breaks on — the reader already resolves absence the same way (D4), so `reventless-ui` owes one test,
not a release ahead of this one. Step 7's `CalendarDate` is the part that genuinely needs the other
repo first: it folds `format: "date"` into its date-time semantic today, so the type would render as
an instant until that is separated.
**Analysis:** the semantic table's date-time row — §4.2 (Group B, "already exists"), §3's
type-vs-annotation table, and §5.7's factory shape — in the repo that owns the cross-repo
semantic-type analysis.
**Builds on:** [done/semantic-type-marker-and-storage-ref.md](./semantic-type-marker-and-storage-ref.md)
— `Semantic.mark` / `Semantic.refined` are the mechanism — and
[done/semantic-branded-scalars.md](./semantic-branded-scalars.md), whose module shape this
follows exactly. [semantic-date-range.md](../semantic-date-range.md) is the consumer: its two parts
are `DateTime` fields and change with it.
**Defers:** [Backlog/semantic-time-of-day.md](../Backlog/semantic-time-of-day.md) — the third member
of the trio, held back on the two blockers stated in D6.

## The gap: the one semantic that never became a type

`DateTime` is the oldest member of the semantic family and the only one that is not a type. It
still lives in `types/` rather than `semantic/` — `reventless/spec/src/types/DateTime.res`, moved
by step 1 — and exposes exactly one value:

```rescript
let string: S.t<string> = S.string->Semantic.mark(~id=Semantic.Id.dateTime)
```

No `type t`, no `fromString`, no validation, no ops. It predates `Semantic.mark` — it was one of the
two bespoke markers (with `Reference`) that the marker plan generalized — and that generalization
re-expressed its *id* on the shared marker without giving it the module shape every later type got.

Two consequences, and the second is the one that costs every day:

**It cannot be named, so it must be annotated.** sury-ppx resolves a field's schema from its type
name (`X.t` → `X.schema`), which is why `Reventless.Money.t` is written bare across the catalog
example — `price: Reventless.Money.t`, no `@s.matches` anywhere. `DateTime` has no `t` for the ppx
to resolve, so every timestamp in the repo is written the long way:

```rescript
@displayName @summary placedAt: @s.matches(Reventless.DateTime.string) string,
```

**It checks nothing.** `Email` rejects what is not an address, `Duration` rejects a negative, `Money`
validates ISO 4217. A `DateTime` field accepts `"tomorrow"`, `"2026-03-02"`, and `""` — and the
example takes that last one up as a sentinel, which §3 of this plan is about.

## The shape

`semantic/DateTime.res`, following `Email` line for line:

```rescript
/** The instant's representation. Transparent `string`: the marker refines an
    existing field rather than replacing it, so nothing stored changes. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

// sury's rule, held once. `fromString` runs it rather than restating it, and
// `schema` is built from `fromString`, so there is exactly one grammar here.
let grammar: S.t<string> = S.isoDateTime

let fromString = (raw: string): result<t, string> => ...
let schema: S.t<t> = S.string->Semantic.refined(~id=Semantic.Id.dateTime, ~check=fromString)

/** Whether a field schema carries the date-time marker. */
let isDateTime = (fieldSchema: S.t<unknown>) => fieldSchema->Semantic.has(~id=Semantic.Id.dateTime)
```

Adoption is then the thing this plan is for:

```rescript
@displayName @summary placedAt: Reventless.DateTime.t,
```

`let string` stays, deprecated, for one release — see step 4.

## Decisions

### D1. Transparent `type t = string`, not abstract

The analysis (§5.7) leans abstract for the branded scalars. `Email` declined that and went
transparent (its own D1), and `DateTime` has the same reason plus a sharper one: these fields are
written from `meta.time`, a plain `string` on the message envelope
([Message.res:32](../../../reventless/spec/src/types/Message.res#L32)). An abstract `t` would put a
`DateTime.unsafe` call at every projection that stamps a row — noise at a hundred call sites to seal
a value the framework itself produced. Transparent keeps `placedAt: meta.time` compiling untouched,
which is what makes step 4 a type-annotation change and nothing else.

### D2. Borrow `S.isoDateTime`; write no grammar

The current module doc says sury has no string-typed datetime format and that `S.datetime`
transforms to `Js.Date.t`. That was true when it was written and is now stale — `sury@11.0.0-rc.2`
binds `isoDateTime` as a plain `S.t<string>`
([node_modules/sury/src/S.res:445](../../../node_modules/sury/src/S.res#L445)) and emits
`format: "date-time"` from it natively. Probed:

```
accept "2026-03-02T09:00:00Z"          accept "2026-03-02T09:00:00.123456Z"
reject "2026-03-02"                    reject "not-a-date"                   reject ""
```

So the branded-scalars rule holds unchanged: one grammar, somebody else's, never a second regex here.

### D3. UTC only — sury's rule, kept rather than widened

`S.isoDateTime` accepts `Z` and **rejects an offset**: `"2026-03-02T09:00:00+01:00"` and a bare
`"2026-03-02T09:00:00"` both fail. That is stricter than RFC 3339, and it is the right strictness to
adopt rather than work around. Every instant the framework produces comes from
`Message.nowAsISOString` — `Date.make()->Date.toISOString`
([Message.res:92](../../../reventless/core/src/Message.res#L92)) — which is always `Z`. A normalization
rule ("instants are stored in UTC") is a fact a reader can rely on; a tolerance rule ("we accept
whatever offset arrived") pushes the zone question onto every consumer.

The one place this bites is an inbound translation carrying a supplier's local offset. That is
exactly what an `InboundTranslation` slice is for — convert at the boundary, `Date.fromString` then
`toISOString` — and the type now makes forgetting it a rejection instead of a row nobody can sort.
State it in the module doc.

### D4. Retire the `""` sentinel — this is the plan's real cost

Two view fields use `""` for "has not happened yet", and both are written through a schema that
would now reject it:

- `Orders.shippedAt` — `Orders_Projection.res:30` writes `shippedAt: ""` on `OrderPlaced`
- `NotificationDeliveries.settledAt` — `NotificationDeliveries_Projection.res:38`, same shape

Refinement runs on the **write** path, not only on read. `QueryDb_Operations` encodes state with
`Message.encode(ReadModelSpec.stateSchema)`
([QueryDb_Operations.res:126](../../../reventless/core/src/components/QueryDb/QueryDb_Operations.res#L126)),
and a refined schema throws there — verified against sury directly:

```
encode ok:     {"a":"2026-03-02T09:00:00Z"}
encode threw:  {"a":""} — Failed at ["a"]: Expected UTC date-time
```

So the sentinel is not a detail to tidy afterwards; it blocks the grammar. `option<DateTime.t>` is
what the field always meant, and the type is what forces the admission.

**It touches the UI repo, but does not wait on it.** `AutoLifecyclePath` reads `shippedAt: ""`
deliberately — there are tests named for it ("An order that has not shipped carries
`shippedAt: \"\"` …", `AutoLifecyclePathTests.res:520`) — so the first reading of this was that the
reader must learn `null`/absent before the writer stops sending `""`. It already has: the strip's own
plan checked the path and found that stamp resolution "decodes a string and yields nothing for `null`
or an absent key, by the same path that yields nothing for `\"\"` — so there is no blocker here, only
a missing assertion"
([reventless-ui `a-strip-reads-the-trail-it-was-given.md`](../../../../reventless-ui/docs/plans/a-strip-reads-the-trail-it-was-given.md),
§4). What the other repo owes is a sibling test for `null` beside the existing empty-string one, and
that test is what lets step 3 land here without waiting on anything.

So step 3 is its own step for the reason below it — a golden and an SDL nullability change should not
ride along with a type refactor — not because it is gated across repos.

Also `String!` → `String` in `examples/online-shop-hybrid/schema/domain-api.graphql` (lines 655, 831)
— a golden refresh in the same commit, per the goldens convention.

### D5. `TestFixtures.time` is `"time"`, and must become an instant

[reventless/gwt/src/TestFixtures.res:6](../../../reventless/gwt/src/TestFixtures.res#L6) stamps every
GWT message with `time: "time"`. That literal flows into projection expectations across the example
suites (`placedAt: "time"`, `shippedAt: "time"`). The two other harness fixtures already use real
instants (`StubRuntime.res:32`, `SideEffect_GWT.res:102`); this one is the outlier. Change it to a
fixed instant and update the expectations — mechanical, but it must land before the grammar or every
projection GWT goes red at once.

### D6. `CalendarDate`: yes. `TimeOfDay`: not yet

**A date-only type earns its place.** `birthDate`, `dueDate`, `effectiveFrom`, an invoice date — the
value has no instant in it, and storing one as a `DateTime` creates the midnight bug: a renderer that
localizes `2026-03-02T00:00:00Z` shows *March 1st* to anyone west of Greenwich. That is a wrong date
on a screen, produced by a correct renderer, and no annotation can fix it because the value itself
lost the distinction. The grammar is free — `S.isoDate` is bound
([S.res:455](../../../node_modules/sury/src/S.res#L455)), accepts `"2026-03-02"`, rejects `"09:00:00"`,
`"2026-03-02T09:00:00Z"`, `""` and `"2026-13-02"`, and emits `format: "date"`, which is the standard
JSON Schema keyword a consumer already knows how to read.

**Named `CalendarDate`, not `Date`.** `reventless-spec` compiles with `-open RescriptCore` and its
own modules resolve unqualified inside the package, so a `Date.res` there would shadow the stdlib
`Date` for every file in it — including `CheckLifecycleModel.res:324` (`Date.now()`) and
`DateRange.res:91` (`Date.fromString`), both of which would break. The wire vocabulary id stays the
short `"date"`; only the module name carries the qualifier.

**A time-of-day type should wait**, on two independent grounds:

- **sury's `isoTime` answers a different question.** Probed, it requires an offset — `"09:00:00Z"`
  and `"09:00:00+01:00"` accept; `"09:00:00"`, `"00:00:00"`, `"23:59:59"` and `"09:00:00.000"` all
  reject. That is RFC 3339 `full-time`, an instant-within-a-day. A domain "time of day" is a *wall
  clock* reading — a shop opens at 09:00 — and has no offset by definition. So unlike the other two
  there is no grammar to borrow, and we would be hand-rolling the regex the branded-scalars plan
  exists to avoid.
- **A wall-clock time is meaningless without a zone, and nothing here carries one.** The notification
  trait already records this gap in its own words: "Nothing in the framework carries a recipient
  timezone" ([trait-notification.md:317](../trait-notification.md#L317)). A `TimeOfDay` would declare
  a value the platform cannot correctly render or compare — a type whose whole promise is that the
  declaration is trustworthy.

Revisit when a field needs it (opening hours, a daily cutoff) *and* a timezone has somewhere to live.
The right shape is then probably `TimeOfDay` beside a zone, not a bare one — which is a composite,
and a composite is a different plan. It is written as one:
[Backlog/semantic-time-of-day.md](../Backlog/semantic-time-of-day.md), which carries both blockers
above in full, the zone-location decision they turn on, and the fact this plan's own investigation
turned up — `Schedule.rate` already holds a time of day as a positional `(hour, minute)` pair, which
is the shape a type would replace.

### D7. A ppx check read the literal `string` keyword, and the plan's own example tripped it

Found in the build, not in the reading. `@displayName` is on `Orders.placedAt` — the field the plan
quotes as its example of what adoption looks like — and `DisplayNameInference` refused it:

```
@displayName only supports string and option<string> fields
```

The check matched `Ptyp_constr (Lident "string")`, so it saw the brand rather than the string.
`DateTime.t` *is* a `string` at runtime, and the joined display name reads it as one — the local
round-trip below returns `displayName: "2026-09-07T22:59:19.102Z"`, taken straight off the branded
field. Left as it was, declaring a field's semantic would have cost it whatever the check gates,
which is exactly the trade a nameable type exists to remove.

Fixed at the source rather than at the call site: `Util.branded_string_modules` names every
`type t = string` in `semantic/` — all twelve — matched through the package namespace as well as
bare. A list rather than a rule because the ppx has only the syntax: it cannot see that
`type t = string`, and guessing from the module name would let `Money.t` through. The types that are
not strings are absent for that reason and not by oversight: `Money` is a record, `Duration` an int,
`Percent` and `Bytes` floats.

`@displayName` takes any of the twelve. Whether an `ImageRef` reads as a row's *name* is not a
question this pass should answer — an explicit `@displayName` is the author saying which field names
the row, and `Plugin_Structure.isLabelShape` already makes the "not prose" judgement on the path
where nobody said (it warns and falls back to `id`). Trusting the declaration and judging the
inference is a distinction the codebase already draws.

**`@owner` was widened too, and the first version of this note was wrong about it.** It said nothing
wants an owner on an instant — true of `DateTime`, and it does not carry to the rest of the list:
`@owner email: Reventless.Email.t` is an ordinary shape, and it was a compile error.

Widening it is *not* the one-line change `@displayName` was, and the difference is the reason to
write this down. `@displayName` never touches the field's schema — it collects names and joins
values. `@owner` injects an `@s.matches`, and on a bare `Email.t` the schema it would replace is the
one sury-ppx derives from the type name, which this pass cannot see. Taking the existing
`Owner.string` branch would have type-checked, satisfied any "is the field marked" test, and left
the field a plain owner-marked string with the address grammar gone — breaking the *composes, never
subtracts* rule the pass is built on, silently. So a branded field takes the composing branch
instead, deriving the schema name by the sury convention `@offload` already uses (now held once, in
`Util.schema_lident_of_type_lident`):

```rescript
email: s.m(Owner.mark(Email.schema))   // not: s.m(Owner.string)
```

Four of the twelve — `MemberRef`, `StorageRef`, `UploadableFile`, `UploadableImage` — build their
schema from a function (`forStore` / `forField` / `forCollection`) because it takes arguments, so
there is no name to derive and no convention to follow. The list carries a flag saying so, and
`@owner` still refuses them; in practice such a field always carries an explicit `@s.matches`, which
reaches the composing branch anyway.

`@ref`, `@storageRef` and `@sensitive` keep their literal-`string` checks. `@ref` on a `Color.t` is a
mistake rather than a use case, and `email`/`phone` are already sensitive with no annotation via
`Sensitive.impliedBySemantic` — widening on the strength of a case nobody has is how the next
surprise gets in. Two passes skip a branded field silently rather than refusing it —
`DcbTagInference`'s auto-tag and `SidecarEmit`'s `autoString` role — but both are reachable only
through a `*Id`-named field of a branded type, and no brand in the list is an id.

`BrandedMarkerCompositionTest` pins the part that would otherwise fail in silence: the field is the
owner, it keeps the `email` semantic, **and it still rejects `"buyer"`**. The marker assertion alone
would pass under the substituting fix; the rejection is what says the brand survived.

## Steps

Ordered so the tree is green after each one, and so the grammar is never switched on while a known
violation of it exists.

They landed in one commit, and step 4 folded into step 1 as a consequence of that ordering: nothing
reads `schema` until step 5 adopts it, so building it refined from the start switches the grammar on
for no existing caller. The step remains written out because the *sequence* is what matters — a
separate landing still has to do 2 and 3 before 5.

**1. The module.** Move `types/DateTime.res` → `semantic/DateTime.res` with `git mv`, add `type t`,
`unsafe`/`toString`, `grammar`, `fromString`, and `schema` per the shape above. `isDateTime` keeps its
current body — it reads the marker, which `Semantic.refined` still sets, so
`SchemaType.isDateTime` ([SchemaType.res:34](../../../reventless/core/src/components/Api/SchemaType.res#L34))
and everything downstream of it are untouched. Keep `let string` exported and deprecated. Rewrite the
module doc: the "sury has no string-typed datetime format" paragraph is now false, and D3's UTC rule
belongs there. Ops worth having, matching the family: `format`, and `compare`/`isBefore` (`DateRange`
already has the `Date.fromString->Date.getTime` idiom at `DateRange.res:91` and should call these
instead of repeating it).

No adopter changes yet — after this step the repo still compiles with every existing `@s.matches`.

**2. `TestFixtures.time`.** `"time"` → a fixed instant. Update the GWT expectations that quote it
(`Orders_GWT.res`, `OrderingFlow_GWT.res`, the notification suite). D5.

**3. Retire the sentinels.** `Orders.shippedAt` and `NotificationDeliveries.settledAt` become
`option<...>`; projections write `None` instead of `""`; SDL goldens refresh in the same commit. The
UI already treats absence as not-yet (D4), so nothing gates this — tell that repo it can drop its
`null` assertion in beside the empty-string one whenever it likes.

**4. Turn the grammar on.** `schema` becomes `Semantic.refined` rather than `Semantic.mark`. Nothing
in the tree violates it by now, which is the point of steps 2–3.

**5. Refactor every call site.** All of them, and the list is short — the annotation is rarer than it
feels:

| File | Fields |
|---|---|
| `examples/online-shop-hybrid/ordering/src/Order/StateViewStream/Orders.res` | `placedAt`, `shippedAt` |
| `examples/online-shop-hybrid/ordering/src/Notification/StateViewStream/NotificationDeliveries.res` | `decidedAt`, `settledAt` |
| `reventless/spec/src/semantic/DateRange.res` | `start`, `end_` (internal, `@s.matches(DateTime.string)`) |
| `reventless/core/tests/api/SuryToJsonSchemaTest.res` | 3 occurrences |
| `reventless/core/tests/plugin/PluginStructureTest.res` | 4 occurrences |

Each becomes `field: Reventless.DateTime.t` (bare, ppx-resolved) except the test fixtures, which
build schemas by hand with `s.matches(...)` and take `Reventless.DateTime.schema` instead.
`DateRange`'s two parts keep their own marker either way — the property the date-range plan relies on
(§"the two instants keep their own `dateTime` markers") is unchanged, since `schema` carries the same
id `string` did.

[lifecycle-trail-on-a-state-view.md](./lifecycle-trail-on-a-state-view.md) added a sixth occurrence
in `entry<'state>`. It landed second, so `at: Reventless.DateTime.t` was written bare from the start.

**One consumer outside this repo gets a fix rather than a migration.** `reventless-tools`' codegen
emits a modelled date-time field as a bare `string` with no marker at all
(`SpecEmitter.renderTypeRef`), so a generated spec loses `format: "date-time"` and every view keyed
off it. Teaching that emitter to write annotations would be a mechanism; a nameable type makes it
`DateTime => "Reventless.DateTime.t"`, one line. Recorded there, in
`docs/plans/forward-codegen-pipeline.md` § *Known gap*, along with the matching one for step 7 — its
import path collapses the source format's `Date` into `DateTime` because `Model.fieldKind` has no
day, which is a distinction the upstream model was already making and this repo had nowhere to keep.

**6. Delete `let string`** in the following release, once no caller remains.

**7. `CalendarDate`.** `semantic/CalendarDate.res` on the same template, `grammar = S.isoDate`, new
vocabulary id `Semantic.Id.date = "date"`. Emission: give it a `SchemaType` case so it surfaces
`{type: "string", format: "date"}` the way `DateTime` surfaces `date-time` — but unlike `DateTime`,
**do not** add it to the exclusion list at
[SchemaType.res:84](../../../reventless/core/src/components/Api/SchemaType.res#L84), so it also carries
`x-reventless-semantic: "date"`. `DateTime`'s exclusion exists because its bare-`format` output is a
published contract that predates the marker; a new semantic has no such history and should arrive
speaking the current vocabulary as well as the standard keyword. No adopter in this repo yet — add
one to the hybrid example only if a genuinely date-only field turns up; a contrived one would be
worse than none.

**The reader must be separated first, and this is a real prerequisite.** `AutoSemantics` folds the
two formats into one semantic today —
`| Some("date-time") | Some("date") => Some((DateTime, "format:date-time"))`
([AutoSemantics.res:896](../../../../reventless-ui/reventless/ui/src/auto/AutoSemantics.res#L896)) —
so a `CalendarDate` field emitted with `format: "date"` renders as an instant, which is the midnight
bug this type exists to prevent, arriving through the type meant to prevent it. Separating the two
semantics in `reventless-ui` ships before any adopter, per the reader-first rule. Its natural home is
that repo's `autoui-date-basis.md`, which owns the question of which date a view's date mode runs on.

## Verification

All of it ran. What each one said:

- **`DateTimeTest`** (14) — the grammar's accepts and rejects from D2/D3, the offset rejection pinned
  as the decision it is, `fromString`'s error text, `format`, `isBefore`/`compare`.
- **`SuryToJsonSchemaTest`** — a `DateTime.t` field emits `{"type": "string", "format": "date-time"}`
  and **no** `x-reventless-semantic` key, asserted as one tuple so the no-drift claim fails loudly
  rather than in halves.
- **`CalendarDateTest`** (10) + its emission block — `{type, format: "date"}` **plus** the semantic
  key, per step 7's deliberate asymmetry, and a check that it does *not* answer to `isDateTime`.
- **`pnpm run check:graphql`** — drift was exactly the two lines step 3 predicted and nothing else:
  `Ordering_Order.shippedAt` and `Ordering_NotificationDelivery.settledAt`, `String!` → `String`.
  Goldens refreshed in the same commit.
- **`pnpm test`** — 395 suites, 4284 tests, all green; `check:lifecycle`, `check:dcb-scope`,
  `check:traits` and `test:projects` likewise.
- **A live local round-trip** on the hybrid platform (in-memory, alt ports): the SDL carries
  `shippedAt: String`; a placed order reads
  `{lifecycle: "Placed", placedAt: "2026-09-07T22:59:19.102Z", shippedAt: null}` and, after
  `Ordering_ShipOrder`, `{lifecycle: "Shipped", shippedAt: "2026-09-07T22:59:25.570Z"}`. `displayName`
  came back as the `placedAt` instant, which is what proves D7's fix on the real write path. No
  projection error in the log — the risk below, checked rather than assumed.
- **`BrandedMarkerCompositionTest`** — `@owner` and `@displayName` on branded fields, with the
  emitted schema checked by what it *rejects* rather than by what it carries. See D7.
- **Full `pnpm run build`** with zero warnings, and `git ls-files --deleted` clean after the `git mv`.

## Risks

- **Step 3 changes a value another repo reads.** Checked, and it is not a sequence: the UI resolves
  absence the same way it resolves `""` (D4). The second-reader worry was settled by grepping both
  repos — every UI path to a date value goes through a `decodeString` that yields nothing for `null`,
  and `Orders` already carries three nullable fields (`deliveryWindow`, `firstProductName`,
  `firstProductImage`), so the shape is one the shell exercises today.
- **A refinement on the write path fails a projection, not a request.** Every writer of the five
  fields was checked to be `meta.time` before the grammar went on, and the round-trip above wrote
  both an instant and an absence through the refined schema with no projection error.
- **`CalendarDate` has no adopter, and must not get one here first.** `reventless-ui` folds
  `format: "date"` into its date-time semantic
  ([`AutoSemantics.res:896`](../../../../reventless-ui/reventless/ui/src/auto/AutoSemantics.res#L896)),
  so the first field to declare a day would render as an instant — the midnight bug arriving through
  the type that exists to prevent it. Landing the type alone changes nothing emitted, which is why it
  is safe now and why the gate is on the adopter, not on the module. That repo's
  `autoui-date-basis.md` owns the separation and already states it.
- **`S.isoDateTime` is from an RC pin** (`11.0.0-rc.2`). Its acceptance set is quoted above rather
  than described so a future sury bump has something to diff against. Note in passing: its `isoTime`
  rejects `"09:00:00.000"`, which looks like a bug — another reason D6 does not build on it yet.
