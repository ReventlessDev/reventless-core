# Plan: `Money` and a closed `Currency`

**Date:** 2026-07-31
**Status:** Complete — all six steps done across both repos. Three decisions changed on contact with
the code and are recorded in place below (`amount` is `float`, not `int`; the wholeness check sits on
the amount field rather than the record; `money` is a *new* UI semantic beside the existing
`currency`, not a widening of it). Core build clean, suite 2483/2483; UI suite 1159 passing with the
same two pre-existing failures as on an untouched tree. Verified end to end against a live local
platform, seed included.
**Repos:** `reventless-core` **and** `reventless-ui` — unlike the branded scalars, this one does need
UI work: `Money` is the first semantic type whose renderer cannot be derived from an existing
primitive cell, and it is the first to contribute a *view-level* capability.
**Analysis:** `autoui-semantic-types.md` §15.1 (the shape), §7.2 (the capability contribution),
§10.1 (standard at the boundary), §16 (what it costs the event log) — in the repo that owns the
cross-repo semantic-type analysis.
**Builds on:** [done/semantic-branded-scalars.md](./done/semantic-branded-scalars.md) and
[done/semantic-type-marker-and-storage-ref.md](./done/semantic-type-marker-and-storage-ref.md).
`Semantic.mark` is the mechanism; `StorageRef` is the template for a *composite* rather than a brand.

## Why this is not the eighth scalar

The seven branded scalars were safe against any deployment because a brand changes the schema
annotation and not the wire shape — an `Email.t` is still a JSON string. **`Money` turns a number
into an object.** That is the *structural breaking* category verbatim: changing the meaning or unit
of a numeric field, owing an upcaster and a full projection rebuild.

Nothing in this plan removes that obligation; it only states where it lands. A deployment whose log
must survive cannot take this change until the schema-versioning substrate exists
(`Backlog/sury-event-schema-versioning.md`). A deployment whose log can be discarded can take it
today, and the example stacks are in that category. **Whoever schedules this against a log that must
be kept is blocked on that substrate, not on anything here** — and should read this paragraph as the
warning it is rather than as background.

Two consequences that are easy to miss and expensive to discover late:

- **Seed data carries the old shape.** A data set written against `price: float` does not decode
  against `price: Money.t`. Updating it is part of this wave, not a follow-up.
- **The storage shape is permanent from the first event kept.** No migration recovers a currency that
  was never written, which is precisely why §15.1 chose the structural shape on append-only grounds.
  A wipe changes when the log starts, not what a stored value has to mean.

## The shape, already decided

```rescript
type t = {amount: float, currency: Currency.t}   // amount in whole integer minor units
```

Not a branded `amount` scalar with the currency held at the aggregate, and not "support both". The
reason is not ergonomics — it is that **the alternative does not work**: minor units are
currency-dependent (ISO 4217 exponent 2 for EUR, **0 for JPY**, **3 for TND**), so a bare `1000` is
€10.00 or ¥1000 or 1.000 TND. It cannot be rendered, compared, summed or sanity-checked without its
currency. The currency is part of the number's meaning, not metadata about it.

Integer minor units rather than a decimal, for the ordinary reason: `0.1 + 0.2` is not `0.3`, and
money is summed.

### D1. `amount` is `float`, not `int` — changed during implementation

The plan wrote `amount: int`, and `int` is the wrong type to hold a whole number here for exactly the
reason the branded-scalars plan already recorded about `Bytes`: **ReScript's `int` is int32 and sury
enforces it**, so an `int` amount caps at 2,147,483,647 minor units — €21,474,836.47. A framework
money type that cannot express a €22M total is not one, and unlike `Bytes` this shape is *permanent
from the first event kept*.

`float` is exact for every integer below 2^53 (about €90 trillion in cents), so the exactness that
motivated minor units in the first place is fully preserved; the wholeness that `int` would have
given for free is recovered by checking it in the schema. The wire form is identical either way —
both are JSON numbers — so this is a source decision, not a format one.

This is the second time the same int32 trap has been caught one plan later than it was written. Worth
generalising: **a numeric framework type that counts things should start as `float`-plus-a-check.**

### D2. The wholeness check sits on the `amount` field, not on the record

sury 11.0.0-alpha.4 miscompiles a refinement wrapping a *record* schema: the generated function
builds its result object literal above the field reads, so both parse and serialize throw
`ReferenceError: Cannot access 'v0' before initialization`. `Semantic.refined` had only ever been
applied to scalars, so `Money` is the first type to reach it.

The check therefore refines the `amount` field (`@s.matches(amountSchema) float`) and the record
carries the plain `Semantic.mark`. That is not a workaround so much as the honest placement —
wholeness is a property of the amount, not of the pair — and it gives a better error path
(`Failed parsing at ["amount"]`). Worth knowing before the next composite (`DateRange`, `GeoPoint`)
reaches for a record-level refinement.

## The decision this plan turns on: how closed is `Currency`

§15.1 settled *that* `Currency` is a closed type rather than a 3-letter string — a string invites
`"eur"` vs `"EUR"`, and that silent-case-mismatch class has already cost this program a day once. It
did not settle **which codes**, and the answer decides whether `exponent` is a total function, which
in turn is what makes `Money.format` derivable rather than a hardcoded `/100`.

Three options:

1. **The full ISO 4217 active list (~180 codes), generated.** `exponent` is total, no escape hatch,
   and the generator keeps the code list and the exponent table in sync by construction. Cost: a
   large generated variant and a generated decoder.
2. **A curated subset** (EUR, USD, GBP, JPY, CHF, …) with no escape hatch. Small and readable, and
   wrong the first time someone needs a currency nobody listed — a compile error in a *consumer's*
   domain, fixable only by a framework release.
3. **A subset plus `Other(string)`.** Reintroduces exactly the failure the closed type exists to
   prevent, and makes `exponent` partial again. Rejected.

**Took option 1, generated from the standard.** The subset's appeal is that it is small, but the
thing being avoided — 180 constructors — is machine-written and never read in full, while the thing
being risked is a framework release to add a currency. Generation also makes the exponent table
*derived from the same source as the codes*, which is the property that makes `Money.format` correct
for JPY and TND without anyone remembering they are special.

**165 codes, not ~180.** ISO's own table lists 178 codes, of which 13 carry `CcyMnrUnts: N.A.` — the
precious metals (XAG, XAU, XPD, XPT), the bond market units (XBA–XBD), the accounting units (XDR,
XSU, XUA), the testing code XTS and the "no currency" sentinel XXX. Each would make `exponent`
partial, which is the one property the closed type exists to have, and a weight of gold is not an
amount of money. The line is drawn by the standard's own data (`CcyMnrUnts` is a number or it is
not), so it is a derivation rather than a curated opinion — which is what the whole option-1 argument
turned on.

The wire form is the 3-letter code (`{"amount": 1000, "currency": "EUR"}`) — standard at the
boundary, ergonomic shape in the domain. Reaching GraphQL, the closed type becomes a closed type:
`enum Catalog_AddProductPriceCurrency { AED … ZWG }`.

## Steps

**1 — `Currency` in the semantic library.** Done.
[`reventless/spec/src/semantic/Currency.res`](../../reventless/spec/src/semantic/Currency.res),
generated by [`scripts/generate-currency.mjs`](../../reventless/spec/scripts/generate-currency.mjs)
from the standard's own publication, committed beside it as `scripts/iso-4217-list-one.xml`
(published 2026-01-01). `pnpm --filter @reventlessdev/reventless-spec run generate:currency`
regenerates; the output is committed, the way `PlatformCapabilities.res` is.

A payload-less `@schema` variant, so sury emits a union of string literals and the stored form is the
code itself — the wire form falls out of the type rather than needing an encoder. `toString` and
`exponent` are generated switches; `fromString` is *derived* from `all` + `toString`, so a code that
parses and a code that exists cannot become different sets.

**2 — `Money` in the semantic library.** Done.
[`reventless/spec/src/semantic/Money.res`](../../reventless/spec/src/semantic/Money.res), following
`StorageRef`'s template. `Semantic.Id.money = "money"`. Unlike the brands this is not attached with
`@s.matches`: the field's declared type *is* `Money.t` and sury-ppx resolves it to this module's
`schema`, which is what makes it a composite rather than a refinement.

**3 — the smart constructors that make it a value object.** Done. `make` (minor units), `zero`,
`ofMajor` / `toMajor` (scaling by `Currency.exponent` — the one place a decimal may become money, so
`*. 100.0` is written once and is right for JPY and TND), `format`, `add` returning `result`, and
`sum` returning `option<result<…>>` (the sum of no amounts has no currency to be in).

`add` is §15.1's second rider made executable: the genuine appeal of the branded-scalar option was
that mixing currencies becomes impossible, and the answer is to check it, not to delete the
information that makes checking possible.

**4 — retype the example's price fields.** Done, in **`online-shop-hybrid`** — the example that has
a seed data set and is the one CI deploys. `online-shop-aggregates` and `online-shop-dcb` keep
`price: float` deliberately: they demonstrate the two architectural styles, one worked example of the
retype is enough to prove the path, and a three-way sweep would have made a diff nobody can review.

Touched: the extension point and its mapping, `AddProduct` / `ChangeProductPrice` /
`SyncCatalogProduct` commands and events, the `Products` / `AvailableProducts` views, both behaviors,
the `ImportProduct` translation, every GWT fixture, and the seed data set. `catalog-spec` and
`seed-data` gained `@reventlessdev/reventless-spec` as a rescript dependency (the npm dep was already
present on `catalog-spec`; `seed-data` needed both, plus a 3-line lockfile update).

Three things worth reading in the diff, because they are the payoff rather than the cost:

- **`ImportProduct_Translation`** lost both `Int.toFloat(unitPrice) /. 100.0` *and* its USD-only
  guard. They were two halves of one mistake: the divide-by-100 hardcoded a minor unit for the
  currencies that happen to have two, and the USD-only check existed because the domain had nowhere
  to put a currency once it arrived. The supplier already sends minor units and a code, so the
  translation is now a `Currency.fromString` parse and a `Money.make` — and a JPY feed needs no
  special case.
- **Both behaviors' "current price" became `option<Money.t>`.** A zero would have to name a currency,
  and inventing one for a product that does not exist yet is a claim the state cannot support.
- **`DemoCommands.money`** encodes the GraphQL argument as an input object whose currency is an
  **enum**, not a string. That is the one detail a consumer will get wrong, which is why it is
  centralised in the adapter that already owns "how this example's commands reach the API".

**Not updated: the `.model.json` and `.reventless/sync-base/*.json` artifacts** beside the retyped
slices, which still describe `price` as `{"kind": "float"}`. They are produced and consumed by the
event-modeling sync in the tools repo, nothing in this repo reads them, and they carry absolute
paths — hand-editing them would be worse than leaving them to be regenerated. The next sync will show
the change, which is correct.

**5 — the field renderer (ui).** Done. **`money` is a new semantic beside the existing `currency`,
not a widening of it** — the UI already had `currency`, reached by the name heuristic
(`*price`/`*amount`/`*total` on a numeric field) and rendered by `formatCurrency`, which fixes two
decimals and shows no symbol because at that tier there is no currency to show. Widening it would
have made every bare numeric price start decoding as an object. So: a second id, a shape heuristic
(`{amount: number, currency: string}`, ahead of address/geo-point on the same rung), and a cell,
detail, input and validator.

**The exponent is not duplicated into this repo.** `Intl.NumberFormat` already carries ISO 4217's
minor units, so the renderer asks it — correct for JPY and TND, and impossible to let drift from the
standard, which is the same property core's generated table has, arrived at from the other side. An
unlisted-but-well-formed code gets ISO's own default of two decimals rather than a fallback; only a
malformed code falls back to the bare figure.

The input takes **minor units** with the formatted reading live beneath it. Major-unit entry is
friendlier and was rejected for the *default* input on two counts: it rounds what someone typed
(10.005 → 1001, silently), and a controlled field that reformats mid-keystroke fights the caret.
An application that wants decimal entry registers its own input over the semantic, which is what the
registry is for. The currency half is a `<select>` populated from the field's own enum — the closed
type in the domain is what makes it a dropdown here.

**6 — the capability contribution (ui).** Done, and it turned out to fit an existing shape rather
than needing a new one. Dashboard metrics were already a union of two sources with a precedence
ladder (`ui-hints.json` > `@metric`-declared schema fields); the semantic contributes a **third,
lowest rung**, so a view holding a `Money` field offers a sum KPI without anyone writing the field
down twice.

Expressed as data, per the plan's rider: `AutoSemantics.capability` is a one-constructor variant
(`Measure`), `capabilities: semantic => array<capability>` is a table, and `measureFields` is the
only reader. The wider `isCapable` rework will find a value here, not a dispatch to unpick. Note what
is deliberately *not* a measure: `Percent`, `Rating` and `Progress` are numbers too, and summing them
is meaningless — a measure is a quantity that adds.

`AutoDashboard.numberAt` also had to learn to read a money object, in **major** units. Without that,
every aggregate over a price silently returned zero; with it in minor units, every money KPI would
have been a plausible number exactly two orders of magnitude out.

## Verification

- **A field typed `Money.t` emits the `money` id, and an existing `float` price field emits nothing.**
  `SuryToJsonSchemaTest` asserts both, plus that the field's `type` is now `object` rather than
  `number` — the schema diff before and after, stated as a test so it cannot be confused with the
  brands' "shape is unchanged" claim.
- **`Money.format` is correct for a 2-exponent currency, JPY (0), TND (3)** and CLF (4), on both
  sides: `MoneyTest` in core against the generated table, `SemanticRenderersTests` in the UI against
  `Intl`.
- **`Money.add` refuses to add across currencies**, and `sum` refuses at the first mismatch.
- **A seeded example stores and serves money end to end.** Verified against a live local platform
  (memory backend, ports 4300/4301): the GraphQL schema carries `Catalog_AddProductPrice`
  (INPUT_OBJECT) and `Catalog_ProductPrice` (OBJECT) with per-field currency ENUMs; `AddProduct` with
  `price: {amount: 99999, currency: EUR}` round-trips; `ImportProduct` with `unitPrice: 1200,
  currency: "JPY"` stores `{amount: 1200, currency: "JPY"}` **unscaled**, which is ¥1200 and would
  have been ¥12 under the old `/100`; and the seed's 16 products land with EUR amounts in minor
  units. The live plugin structure carries `x-reventless-semantic: "money"`, so the UI resolves it.
- Core: root build clean (zero warnings), `pnpm test` 2483/2483, `test:projects` 16/16,
  `check:outputs` clean. UI: build clean, 1159 tests passing — the two failing suites
  (`RichTextEditorTests`, `ComponentManifestTests`) fail identically on an untouched tree and are
  unrelated. `component-manifest.json` regenerated.

The one item from the original list not exercised: **a dashboard actually offering the price field as
a KPI in a browser.** The derivation and the aggregation are unit-tested, and the metric now reaches
`AutoDashboard` through the same union the other two sources use, but nobody has looked at the
rendered card.

## Out of scope

- **FX and conversion.** Rates, whether historical rates are stored beside converted amounts, and
  rounding policy (half-even vs half-up). All genuinely open, all policy, and all decidable *later
  precisely because* the currency rides on the value. (`ofMajor` does pick a rounding — half away from
  zero — but that is a boundary conversion, and it forecloses nothing about arithmetic policy.)
- **The upcasting substrate.** Named above as the gate for logs that must survive; building it is its
  own work with its own Backlog plan.
- **`DateRange` and `GeoPoint`.** The other two composites. They share this plan's breaking-change
  category but not its decisions, and folding them in would make one plan that cannot be reviewed.
  D2 above is the one thing they should read first.
- **The `isCapable` rework.** Step 6 contributes to it; it does not rebuild it.

## Follow-ups

- **A `Seed.money` helper in `reventless-seed`.** The GraphQL encoding of a money argument — input
  object, currency as an *enum* and not a string — is a framework fact that every consuming app
  currently has to rediscover. It lives in the example's adapter today because `reventless-seed` is
  deliberately generic and does not depend on `reventless-spec`. Worth revisiting the first time a
  second app writes it.
- **The leaderboard shows a money aggregate unlabelled.** `measureDisplay` receives a `float` and has
  no currency to name — correctly, since a sum across rows may not have shared one — so the "top by
  price" card prints a grouped figure. Threading the row's own currency through `topRows` would fix
  the per-row case; it is a small change and nobody has asked for it.
- **`x-reventless-semantic: "money"` on a *command* field is untested in the UI.** The renderer path
  is exercised for views; the input path has unit coverage but no form-level test.
