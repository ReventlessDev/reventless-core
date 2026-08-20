# Plan: `Geolocation` — the geocoder's answer as one value

**Date:** 2026-08-20
**Status:** Proposed. Nothing implemented. **Blocked on**
[tagged-union-state-fields.md](./tagged-union-state-fields.md) — the framework cannot express a
tagged-union field until that lands, and this type is one.
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
query**, not a degraded one — the view fails outright rather than losing a control. So the reader
half's generic union support must ship **before or with** this plan, never after. `GeoPoint` had the
same shape of constraint with a gentler failure (a map silently not offered); this one takes the view
down.

**Events are untouched.** `LocationSet`, `AddressLocated` and `AddressUnresolvable` are already a
discriminated union carrying exactly these three outcomes. Nothing stored needs upcasting, and the
projection's five arms map one-to-one onto the new value.

## Steps

**1 — `Geolocation` in the semantic library.** `reventless/spec/src/semantic/Geolocation.res`, beside
`Geocoding` and depending on `GeoPoint`: the `@schema` variant above, the `schema` shadow carrying
`Semantic.mark(~id=Semantic.Id.geolocation)`, `ofSearch` per D5, and the small accessors a consumer
needs without matching arms (`point: t => option<GeoPoint.t>`, `isLocated`, `reason`). Accessors rather
than arm matches at consumers is `DateRange`'s discipline and the reason it held.

**2 — the marker and the canonical name.** `Semantic.Id.geolocation`, and an entry in
`semanticCompositeNames` ([SchemaType.res:51-55](../../reventless/core/src/components/Api/SchemaType.res#L51-L55))
so the union is emitted as `Geolocation` for every field that uses it rather than once per field path.
This is what makes each plugin's copy byte-identical, which is what merged-API composition requires —
the same property `Money`, `DateRange` and `GeoPoint` already rely on, and it matters more for a union
than for an object, since a union's members are named types too.

**3 — the example adopts it.** `Customers` drops `location`, `locationStatus` and `locationNote` for one
`geolocation: Geolocation.t`. The five arms in `Customers_Projections` each write one value:
`Registered` and `AddressUpdated` produce `Pending({requestedFor: address})`, `LocationSet` and
`AddressLocated` produce `Located({point})`, `AddressUnresolvable` produces `Unresolvable({reason})`.
Both `UpdateWithDefault` defaults carry `Pending`. The GWT fixtures follow.

The GraphQL golden `examples/online-shop-hybrid/schema/domain-api.graphql` is refreshed **in the same
commit** — for this change the schema diff is the review artifact, more than the ReScript is.

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

**5 — the reader half, planned in `reventless-ui`.** What this plan owes it, beyond the mechanism
plan's contract:

| What the UI reads | Fixed by |
|---|---|
| `x-reventless-semantic: "geolocation"` on the field | step 2 |
| one spelling only — `geolocation`, in both vocabularies | D3 |
| three members, named `GeolocationPending` / `GeolocationLocated` / `GeolocationUnresolvable` | step 2 + the mechanism's member naming |
| the point lives on `Located` alone, so a map pin is drawn from one arm and never from an absent field | the shape |
| a row with no point is `Pending` or `Unresolvable`, and those are different — the first waits, the second wants a human | D1 |

The last row is the whole reader-side point. A control that renders both as "no location" throws away
the distinction this plan exists to create.

## Verification

- **The fourteen doors.** Every read door in the mechanism plan's D1 table, against a deployed
  `Customers` carrying a real union: AppSync's single, single`Items`, list, by-index, by-ids, refs,
  `@resolves` and `@resolvesMany`; the Postgres resolver; and local's six. **Each one called, none
  sampled.** This is the evidence the mechanism plan could not gather and the reason this plan exists
  as a separate one — a union field missing `__typename` resolves to null, and a null in a non-nullable
  field nulls its parent, which inside a list is every row disappearing. The by-index and `@resolves`
  doors are the likeliest to be skipped, since `Customers` does not exercise them itself; give them a
  fixture rather than an exemption.
- **A pre-existing row is rebuilt, not decoded.** Assert the *failure* deliberately: a row written in
  the three-field shape does not parse against the new schema. This is the plan's breaking claim, and
  a plan that asserts its cheap claims and assumes its expensive one has it backwards.
- **`ofSearch` maps every outcome, including the one that maps to nothing.** All four rows of D5's
  table, with `Unavailable` asserted to return `None` — the single most consequential branch, since
  getting it wrong converts an outage into a permanent verdict.
- **The SDL golden diff is read, not just regenerated.** Three member types, one union, and the three
  old fields gone. Regenerating a golden without reading it is how a wrong contract gets committed with
  a green build.
- **A live local round trip, then a browser.** A customer registered with a plain address, geocoded, and
  the detail page showing one Geolocation control where three rows are today — then the same page while
  the address is changed, which should return it to `Pending` and clear the pin. `GeoPoint`'s
  verification carries its own note that nobody opened a map; the equivalent mistake here is a
  `Pending` row and an `Unresolvable` row rendering identically, which only a person looking at both
  will catch.

## Out of scope

- **The geocoding transport.** Which provider answers, and how, stays where it is. This plan types the
  answer.
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
