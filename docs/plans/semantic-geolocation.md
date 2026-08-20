# Plan: `Geolocation` — the geocoder's answer as one value

**Date:** 2026-08-20
**Status:** Steps 1–4 implemented, 2026-08-20. `Customers` now carries one `Geolocation` union in place
of a point, a status enum and a note, and the SDL golden moved with it. **Unreleased and undeployed** —
the breaking retype below is real, so the alpha store needs a wipe and a replay when this goes out.
Step 5 (the dedicated UI control) may safely lag; the generic union renderer already ships.
What is **not** covered is the AppSync and Postgres half of D1's read doors, which needs the deploy —
see *Verification*.
[tagged-union-state-fields.md](./done/tagged-union-state-fields.md) landed first, so the framework can
express, emit and store a tagged-union field; its reader half shipped too, as
`reventless-host-shell@3.0.0-alpha.81`, which the examples pin — so the hard lockstep below is
satisfied *before* the adopter exists rather than during it. (`alpha.80` shipped the reader but dropped
an arm's nested point from the list selection, which would have cost this view its map pins; `.81` is
the one that carries them.) One thing the mechanism added that step 1
owed: a union carries its own name on its schema, so `Geolocation` writes
`Reventless.TaggedUnion.named(~name="Geolocation", …)` beside its `Semantic.mark` — that name is
what both the emitted `union Geolocation` and the stored `__typename` are built from.
**Scope:** the semantic type, the first view to adopt it, and the deployment proof the mechanism plan
deliberately cannot gather.
**Repos:** `reventless-core`, with a reader half in `reventless-ui` planned there. The lockstep is
hard — see *What it costs a deployment*.
**Builds on:** [semantic-geo-point.md](./semantic-geo-point.md) — this is the state `GeoPoint` sits
inside — and [done/semantic-money-and-currency.md](./done/semantic-money-and-currency.md) for the
composite template.

## What this replaces

Two things, and they are the same mistake at two altitudes.

### One fact spread across three fields

`Customers` spends three fields on one three-state fact
([Customers.res:57-75](../../examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/Customers.res#L57-L75)):

```rescript
location: option<Reventless.GeoPoint.t>,
locationStatus: locationStatus,       // Pending | Located | Unresolvable
@hidden locationNote: option<string>,
```

Twelve representable combinations for three legal ones. `Located` with `location: None` compiles.
`Unresolvable` with a stale point still on the row compiles. `Pending` carrying a note compiles. What
keeps the twelve down to three is the five-arm switch in
[Customers_Projections.res:42-99](../../examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/Customers_Projections.res#L42-L99)
remembering to write all three fields on every arm — in both the aggregate mapping and the DCB one,
and in both `UpdateWithDefault` defaults. Six places that have to agree, forever, by hand.

The file already makes this argument against itself. Twenty lines up, `accountStatus` is a variant
rather than an enum-beside-a-flag, and the comment says why: "The alternative — an `accountStatus`
enum AND a `deactivated: bool` — is the same fact twice, with nothing keeping the two in step." The
same sentence applies verbatim to the three fields below it. It was not applied because the framework
could not express the type.

### The answer `Geocoding` has no type for

[Geocoding.res](../../reventless/spec/src/semantic/Geocoding.res) already owns the hard half of this
domain: `candidate`, the two-armed `failure`, and `confidentMatch`, whose doc makes exactly the
argument this plan extends — a caller that re-derives the confidence rule "produces a plausible marker
in the wrong region, drawn without an error anywhere."

What that module has no type for is **the answer**. `confidentMatch` returns `option<candidate>`,
where `None` means "ask a human" rather than "no result", and every caller then decides on its own
what to write into a row: which fields, in which combination, with what note. That decision is
re-made at each consumer — the same shape of mistake `confidentMatch` exists to prevent, one level up.

`Geolocation` is that module's missing return type. Which is the strongest available argument that it
belongs in the framework's vocabulary rather than in an example: the module it completes is already
there.

## The shape

```rescript
@schema
type t =
  | Pending({requestedFor: string})
  | Located({point: GeoPoint.t})
  | Unresolvable({reason: string})
```

Serialising as `{"TAG":"Located","point":{"lat":48.2082,"lng":16.3738}}`, and reaching GraphQL as a
three-member union. Inline records rather than positional payloads, and no arm without a field —
both are the mechanism plan's D2 and both are GraphQL constraints rather than taste.

### D1. Three states, because two cannot say what the third means

`option<GeoPoint.t>` on its own is the shape this replaces, and `None` in it means two different
things: the geocoder has not run, and the geocoder ran and failed. An operator cannot act on a state
that means two things — they cannot tell whether to wait or to fix the address. `Customers.res`
already says this in a comment; the type now says it instead.

The asymmetry is deliberate: `Pending` and `Unresolvable` are both "no point", and collapsing them is
exactly the collapse being undone.

### D2. `Pending` carries the address it is pending on

The mechanism's D2 requires every arm to declare a named field, so `Pending` has to carry something —
and there is a real candidate rather than filler. `requestedFor` is the address the geocoder was asked
about, which makes "is this answer still about the current address?" answerable from the value alone.

The aggregate already treats that question as first-class: `SetLocation({location, resolvedFrom})`
carries `resolvedFrom` as, in its own words, "a staleness token as much as provenance: an answer for an
address that has since changed is dropped rather than applied"
([Customer.res:45-52](../../examples/online-shop-hybrid/ordering/src/Customer/Aggregate/Customer.res#L45)).
`requestedFor` is the read side of the same idea.

**What this deliberately does not do is put that field on all three arms.** A common member field is
the case that would justify a GraphQL *interface*, which the mechanism plan puts out of scope — and
building a union whose every arm shares a field is building an interface without saying so. If the
shared field turns out to be wanted on `Located` and `Unresolvable` too, that is the evidence to
reopen the interface question, not a reason to pre-empt it here.

### D3. One spelling, for once

`geoPoint` had to be accepted under two spellings because core's semantic vocabulary is camelCase and
the UI's is kebab-case, so `geoPoint` and `geo-point` both had to resolve — same for `dateRange` /
`date-range`. `geolocation` is a single lowercase word and is **identical in both vocabularies**. It
arrives with one spelling, and the reader half should not add a second out of habit.

### D4. Not the record's `@lifecycle`, and now not annotatable as one either

The current field is called `locationStatus`, and the temptation to annotate it `@lifecycle` is exactly
what `Customers.res` warns against: no command branches on it and no lifecycle passes through it. It is
a background job's progress, not where the customer is in their life with the shop — `accountStatus` is
that, and carries the annotation.

Under the mechanism plan this stops being a matter of discipline: `@lifecycle` on a union field is a
compile error, because `deriveServerCapability` cannot build a filter from one. The type and the guard
now say together what a comment said alone.

### D5. The bridge from a geocoder answer lives on the type

`Geolocation.ofSearch(~requestedFor, result)` — taking what `Geocoding.search` returns
(`result<array<candidate>, failure>`), applying `confidentMatch`, and producing the arm:

| Geocoder outcome | Arm |
|---|---|
| a confident candidate | `Located({point})` |
| candidates, none confident | `Unresolvable({reason})` — ambiguous or low-relevance, said in the reason |
| `Error(NoMatch)` | `Unresolvable({reason})` |
| `Error(Unavailable(_))` | **no arm** — the row stays `Pending`; retry is owed |

That last row is the reason this helper exists rather than being written per caller. `Unavailable` is
the one outcome that must *not* become a verdict — [Geocoding.res:32-45](../../reventless/spec/src/semantic/Geocoding.res#L32-L45)
says a translator that cannot tell "no such address" from "the service is down" turns one outage into a
permanent verdict on every address in flight. Returning `option<t>` from `ofSearch`, with `None`
meaning "leave the row alone", is what makes that hard to get wrong at the call site.

## What it costs a deployment

**A breaking retype and a projection rebuild.** Three fields become one and the wire shape changes, so
every stored `Customers` row stops decoding. A read model is derived state and replay is what it is for
— this is a rebuild, not an upcaster. On alpha that means a store wipe and a replay; migration code is
for data that has to survive.

**The lockstep is hard, and it is the one to get right.** A union field cannot be selected bare. The
moment `Customers` declares one, a client that has not learned inline fragments sends an **invalid
query**, not a degraded one — the view fails outright rather than losing a control. `GeoPoint` had the
same shape of constraint with a gentler failure (a map silently not offered); this one takes the view
down.

Two things sharpen that into an order of operations.

**It is step 3 that binds, not this plan.** Steps 1, 2 and 4 are inert on a deployment: a type nobody
declares, a marker on nothing, and a doc. Only the `Customers` collapse puts a union into a served
SDL. So the pin can be bumped between step 2 and step 3 as easily as ahead of the whole plan, and
splitting there is the cheaper order whenever the reader half is not ready yet.

**"With" is not available, only "before."** The tempting move is one commit carrying both the host-shell
pin bump and the collapse — one deploy, no window. It does not work, for two reasons that are specific
to this shell and this CDN. The shell reads schemas at **runtime**, querying
`Platform_ComponentDefinitions` off the live platform rather than from anything baked into its bundle,
so every already-open browser starts building queries from the new schema the instant AppSync's SDL
changes — a deploy cannot fix a tab that is already loaded. And CloudFront keeps serving the previous
bundle after a UI deploy until someone invalidates it by hand, so one commit buys one deploy and not one
moment: the window is the cache's length, not the deploy's.

So: bump the pin as its own commit, let it deploy, invalidate, confirm the new shell is being served —
**then** land step 3. The insurance is one line, and it is what makes the SDL change a non-event.

*Where that stands, 2026-08-20.* The first three are already done, and not as a step of this plan —
the pin bump landed on its own, ahead of any adopter, and `alpha.80` has deployed. The
invalidation is no longer a manual step either: the stack invalidates `/*` after the bundle upload
([Plugin_Stack.res:511-523](../../reventless/aws/src/plugin/stack/Plugin_Stack.res#L511-L523)), chained
on the upload etags so it runs after the new content is in S3. It is best-effort by design — a failed
invalidation must not fail a deploy. The served bundle *was* confirmed byte-identical to the published
`alpha.80`, so that check is done and the mechanism works.

**But `alpha.80` turned out to be the wrong target.** It selects a union by its arms — the property the
lockstep argument is about — while dropping a `Located` arm's nested `point` from the list selection,
so this view would have rendered a valid query and an empty map. `alpha.81` fixes the arm's depth
budget, and the pins now name it. What is owed before step 3 deploys is therefore the same check again
against **alpha.81**, which is only meaningful once it has been deployed.

**What it costs to get wrong, for calibration.** The Customers view fails to load on the alpha example
app. Not the platform, not the other views, not production, and the fix is a pin bump and a redeploy or
a revert of the collapse. This is cheap insurance against a self-inflicted breakage, not a
one-way door — worth stating so the ordering reads as prudence rather than as a hazard.

**Events are untouched.** `LocationSet`, `AddressLocated` and `AddressUnresolvable` are already a
discriminated union carrying exactly these three outcomes. Nothing stored needs upcasting, and the
projection's five arms map one-to-one onto the new value.

## Steps

**1 — `Geolocation` in the semantic library.** `reventless/spec/src/semantic/Geolocation.res`, beside
`Geocoding` and depending on `GeoPoint`: the `@schema` variant above, the `schema` shadow carrying
`Semantic.mark(~id=Semantic.Id.geolocation)`, `ofSearch` per D5, and the small accessors a consumer
needs without matching arms (`point: t => option<GeoPoint.t>`, `isLocated`, `reason`). Accessors rather
than arm matches at consumers is `DateRange`'s discipline and the reason it held.

*Done*: [Geolocation.res](../../reventless/spec/src/semantic/Geolocation.res), with
[GeolocationTest.res](../../reventless/spec/tests/GeolocationTest.res) — 19 assertions, D5's four rows
included.

**One thing the plan asked for could not be built as specified.** D5 wants the `Unresolvable` reason to
say *which* rule declined — "ambiguous or low-relevance, said in the reason" — and
`Geocoding.confidentMatch` returns an `option`, which does not say. Producing the distinction in
`ofSearch` meant comparing the top score to the floor a second time, and a second copy of the
confidence rule is precisely what [Geocoding.res](../../reventless/spec/src/semantic/Geocoding.res)
exists to prevent. So the rule was *widened where it lives* instead: `Geocoding.assess` returns
`Confident` / `NoCandidates` / `Unscored` / `LowRelevance` / `Ambiguous`, and `confidentMatch` became a
four-line wrapper over it with its signature and behaviour unchanged — its eight existing tests are the
proof of that, and they pass untouched. `ofSearch` then reports what came back (which candidates, at
what score, against what floor) without restating the rule that rejected it.

The alternative was a single flat reason, and it is worth saying why that was refused: "no confident
match" gives an operator nothing to do, where "matched 'Springfield, IL' and 'Springfield, MA' about
equally well" tells them the address needs a state. The whole point of `Unresolvable` being a state
rather than a note is that somebody acts on it.

**2 — the marker and the canonical name.** `Semantic.Id.geolocation`, and an entry in
`semanticCompositeNames` ([SchemaType.res:51-55](../../reventless/core/src/components/Api/SchemaType.res#L51-L55))
so the union is emitted as `Geolocation` for every field that uses it rather than once per field path.
This is what makes each plugin's copy byte-identical, which is what merged-API composition requires —
the same property `Money`, `DateRange` and `GeoPoint` already rely on, and it matters more for a union
than for an object, since a union's members are named types too.

*Done — as half of what it says.* `Semantic.Id.geolocation` exists and the type carries it. **The
`semanticCompositeNames` entry was deliberately not added, because the mechanism's D3 made it inert.**
That table sets the `parentName` a semantic's shape is walked under, and the union branch
([SchemaType.res:177-198](../../reventless/core/src/components/Api/SchemaType.res#L177-L198)) never
reads `parentName`: the union's name comes off the schema via `TaggedUnion.classify`, and each member's
from `memberTypeName(~union, ~arm)`. An entry would change nothing and would leave two places appearing
to decide one name — the failure mode being that someone later edits the inert one and cannot see why
the SDL disagrees.

The byte-identity this step wanted is still delivered, and delivered *better*: a schema-carried name is
path-independent by construction, where a `semanticCompositeNames` entry only makes it
path-independent for fields that also carry the semantic marker.

Asserted rather than argued —
[GeolocationSemanticTest.res](../../reventless/core/tests/api/GeolocationSemanticTest.res) pins
`canonicalName(geolocation) == None` **beside** the emitted `union Geolocation` with its three members,
so the two facts cannot drift apart quietly. It also pins the thing that has no other guard: that
`Semantic.mark` and `TaggedUnion.named` ride on one schema without displacing each other. Losing either
marker emits the field as `String` — no compile error, no runtime failure, just a degraded contract.

**3 — the example adopts it.** `Customers` drops `location`, `locationStatus` and `locationNote` for one
`geolocation: Geolocation.t`. The five arms in `Customers_Projections` each write one value:
`Registered` and `AddressUpdated` produce `Pending({requestedFor: address})`, `LocationSet` and
`AddressLocated` produce `Located({point})`, `AddressUnresolvable` produces `Unresolvable({reason})`.
Both `UpdateWithDefault` defaults carry `Pending`. The GWT fixtures follow.

The GraphQL golden `examples/online-shop-hybrid/schema/domain-api.graphql` is refreshed **in the same
commit** — for this change the schema diff is the review artifact, more than the ReScript is.

*Done.* The golden diff is the shape this predicted: three fields and the `Ordering_CustomerLocationStatus`
enum gone, `union Geolocation` with its three member types added, `geolocation: Geolocation!` on
`Ordering_Customer`. The platform golden is untouched.

Two notes for whoever reads that diff next:

- **`check:graphql`'s summary reports one line that did not happen.** It printed
  `- Ordering_SendOrderConfirmationTodoStatus.Pending`, which is a *labelling artifact*: the reporter
  diffs raw lines as a multiset and names each by the declaration the walk was last inside
  ([CheckGraphqlContract.res:187-199](../../scripts/CheckGraphqlContract.res#L187-L199)). `  Pending`
  appeared twice in the old golden and once in the new, so the surplus was attributed to the
  alphabetically later of the two enums. The regenerated file confirms that enum keeps all four values.
  Worth knowing before someone chases it; noted as a follow-up below.
- `| AddressUnresolvable({reason}) => … Unresolvable({reason})` does not compile — punning across the
  two inline records makes the source constructor's anonymous type escape its scope. Bind it under
  another name (`{reason: why}`). A one-line fix, but the error names the *target* field, which points
  away from the cause.

**4 — the docs, one of which is already wrong.**
[ui-configuration.md](../../packages/doc/docs-app/ui-configuration.md) names this read model twice, and
the two spots need different fixes:

- **Line 859**, the `Ordering/Customers` row, says `@lifecycle locationStatus`. That is **stale today**,
  before this plan changes anything: the code carries `@lifecycle accountStatus` and says in a comment
  that `locationStatus` is deliberately not the lifecycle. Correct it to the truth, then to the new
  shape.
- **Lines 104-114**, the worked example for `@lifecycle`, illustrates the annotation using
  `locationStatus` — the field this plan deletes, and a field the annotation should never have been on.
  It needs a different subject, and `accountStatus` is the honest one: a record whose lifecycle field is
  named something other than `lifecycle` is exactly what the annotation is for.

*Done, and the second bullet was wrong about its own subject.* That worked example already used
`accountStatus`; nothing was owed there. What actually needed the fix was the paragraph *below* it —
"Not every enum ending in `Status` is one" — which taught the rule using `locationStatus` as its
counter-example, a field this change deletes. It now states the principle generically and adds what is
newly true: the temptation is gone because the enum is gone, and `@lifecycle` on a union field is a
compile error.

Two more the plan had not found, both the same drift: the `@hidden` example was `@hidden locationNote`
(now a generic `internalNote`), and [reventless-ppx.md:418](../../packages/doc/docs-app/reventless-ppx.md)
taught the same lesson with the same doomed field. Left alone deliberately:
`PluginStructureTest` and `Platform_ComponentDefinitions_Lambda_OpsTest` each use the string
`"locationStatus"` in a synthetic fixture that never referenced this view — renaming those is churn.

**5 — the reader half, planned in `reventless-ui`.** What this plan owes it, beyond the mechanism
plan's contract:

| What the UI reads | Fixed by |
|---|---|
| `x-reventless-semantic: "geolocation"` on the field | step 2 — *verified in the live published schema* |
| one spelling only — `geolocation`, in both vocabularies | D3 |
| three members, named `GeolocationPending` / `GeolocationLocated` / `GeolocationUnresolvable` | step 2 + the mechanism's member naming |
| the point lives on `Located` alone, so a map pin is drawn from one arm and never from an absent field | the shape |
| a row with no point is `Pending` or `Unresolvable`, and those are different — the first waits, the second wants a human | D1 |

The last row is the whole reader-side point. A control that renders both as "no location" throws away
the distinction this plan exists to create.

## Verification

**What ran, 2026-08-20.** `pnpm run build` clean; `pnpm test` — 355 suites, 3569 tests, green;
`pnpm run check:graphql:update` with the diff read by hand; the docs site builds; and a live local
round trip against an in-memory platform on alternate ports.

- **The doors.** ✅ *for every door this view has, locally.* `Customers` declares exactly four —
  `Ordering_Customer` (single), `Ordering_Customers` (list/connection), `Ordering_CustomersByIds` and
  `Ordering_CustomersRefs` — and **all four were called against a live server**, each returning
  `__typename` plus the arm's own fields through an inline fragment. Not sampled: called.

  ❌ **The other doors in D1's table are not covered, and two of them cannot be by this view.** The
  spec declares no `@index` and no composite sort key, so the by-index and single`Items` doors do not
  exist for `Customers` at all, and nothing `@resolves` to it. Those need the fixture the plan asked
  for rather than an exemption — and it is still owed. **The eight AppSync doors and the Postgres
  resolver need a deploy**, which is the one thing this verification cannot reach from here.
- **A pre-existing row is rebuilt, not decoded.** ✅ Asserted as the failure it is, in
  [GeolocationSemanticTest.res](../../reventless/core/tests/api/GeolocationSemanticTest.res): a row in
  the three-field shape does not parse against the union-carrying state schema.
- **`ofSearch` maps every outcome, including the one that maps to nothing.** ✅ All four rows of D5's
  table, `Unavailable → None` asserted on its own.
- **The SDL golden diff is read, not just regenerated.** ✅ Read, and it matched the prediction — with
  one reported line that turned out to be a reporter artifact rather than a change (see step 3).
- **The map still gets its pins.** ✅ The one consumer of this field. AutoUI reads `geolocation` as a
  `Geolocated` geo source from `x-reventless-semantic: "geolocation"` **on the union field**, then
  reads `point` out of the `Located` arm by `__typename`/`TAG`. Confirmed against the schema the local
  platform actually publishes, not the IR.

  Worth recording as a near-miss, because it decided which half of step 2 mattered. AutoUI's schema
  walk enumerates **top-level properties only** and hands unions back untouched, so the `geoPoint`
  semantic *inside* the `Located` arm is invisible to it. Had the field shipped without
  `Semantic.mark(~id=geolocation)`, the view would have resolved to no geo source at all and **the map
  mode would simply not be offered** — not a missing pin, no map. The table would have rendered the
  arm honestly, so it would have read as "the map disappeared" with nothing naming the cause.
- **A live local round trip.** ✅ Register → `GeolocationPending{requestedFor: "Stephansplatz 1,
  Vienna"}`; `SetAddressLocation` → `GeolocationLocated{point}`; `UpdateAddress` →
  `GeolocationPending{requestedFor: "Karlsplatz 13, Vienna"}` — the new address, which is D2's
  staleness argument holding end to end rather than only in a projection test.

  Two gaps in this, both honest: the **`Unresolvable` arm was never driven through the API**, because
  no mutation produces it — `MarkAddressUnresolvable` reaches the aggregate from the geocoding slice,
  so that arm is covered by the GWT projection test and not by a live call. And **nobody has opened a
  browser.** `GeoPoint`'s verification carries a note that nobody opened a map; the equivalent mistake
  here is a `Pending` row and an `Unresolvable` row rendering identically, and only a person looking at
  both will catch it.

## Out of scope

- **The geocoding transport.** Which provider answers, and how, stays where it is. This plan types the
  answer.

  *Narrowed in practice.* The **caller** was not out of scope and was initially missed:
  `GeocodeCustomerAddress_Translation` went on calling `Geocoding.confidentMatch` and writing its own
  flat reason, which left `ofSearch` — the helper D5 justified as existing "rather than being written
  per caller" — with no production caller at all. It now goes through `ofSearch`, so the reasons name
  the candidates and the "an outage is not a verdict" rule has one home. The transport underneath is
  still untouched.

  Two seams showed up in the fit, both worth knowing before the next caller: `ofSearch` collapses
  `Unavailable(why)` to `None` and loses `why`, so the slice still matches that arm itself to keep the
  retry message; and `Some(Pending(_))` is unreachable but must still be written, because the return
  type admits an arm the function never produces.
- **Other views.** `Customers` is the case being proved. No other view is retyped until something asks.
- **An interface for the shared "which address" field.** D2's reasoning: build it when two arms
  genuinely need the field, not in anticipation.
- **Filtering or grouping by arm.** Refused by the mechanism plan's guards. "Show me the customers
  whose address could not be resolved" is a real request and wants a derived scalar beside the union —
  the mechanism plan's own follow-up.

## Follow-ups

- **The operator's queue.** Once `Unresolvable` is a state rather than a note, "the addresses needing a
  human" is a view someone will want. That is the derived-scalar follow-up cashed in, and it is the
  first thing that will test whether refusing to index a union was the right call.
- **`resolvedFrom` on `Located`.** The aggregate carries it; the read model currently drops it. Adding
  it is additive under the inline-record shape, which is one of the reasons D2 chose that shape — worth
  doing the first time somebody has to ask "which address is this pin actually for?".
- **A second union semantic.** One entry is not a vocabulary. The mechanism plan's naming rules and
  D2's every-arm-named-field constraint were fitted to this case; the next one — an outcome, an
  approval, a settlement state — is what shows whether they generalise.
- **`translate`'s own body.** *Done, 2026-08-20, and it needed no framework change.* The plan assumed a
  new GWT verb was owed; `whenTranslateMocked` already takes any
  `(id, item) => promise<translateResult>`, which the real `translate` satisfies once a stub
  `Capabilities.t` is applied. Three cases now drive the real body: a confident answer produces
  `SetLocation` with the point, an ambiguous one produces a reason **naming both candidates** — the
  thing the widening of `confidentMatch` into `assess` was for — and an `Unavailable` leaves the TODO
  `Pending` rather than recording a verdict.

  The last one is a strictly better version of the sibling test beside it, which asserts the same
  outcome from a mocked error *string*; this one drives it from a real `Unavailable`.
- **A union behind an index, as a fixture.** The by-index and single`Items` doors carry no union today
  because no view declares both, so D1's table has two entries nothing has ever exercised. A fixture
  view with an `@index` and a union field would close that without waiting for a real view to want one.
- **`check:graphql`'s drift summary mislabels a moved duplicate line.** It diffs raw lines as a
  multiset and names each by the declaration the walk was last inside, so a line appearing in two
  declarations has its surplus attributed to whichever sorts later. This change printed a removal
  against an enum it never touched. Harmless once understood, and a few minutes of somebody's time
  every time it is not.
