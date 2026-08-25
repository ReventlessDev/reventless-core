# Money in the currency's own units, and ten currencies

Status: **done**.

Supersedes two decisions taken in
[semantic-money-and-currency.md](semantic-money-and-currency.md): that an amount
is a whole number of minor units, and that the currency type admits every code
ISO 4217 defines a minor unit for. Both were defensible on their own terms and
both were paid for at every boundary a person touches.

## What changed

**1 — `Money.t.amount` is the currency's own unit, not its minor one.** `10.5`
is €10.50. It used to be `1050`.

The old reason was exactness: `0.1 +. 0.2` is not `0.3`, and money is summed.
That reason was real, and it is answered rather than dropped — `Money.add`
scales to whole minor units, adds there and scales back, so addition is still
exact. What changed is where the scale lives. It is now an implementation
detail of arithmetic instead of a tax on every form field, every fixture, every
log line and every person reading a price off the wire.

The cost the old shape had stopped hiding: a form generated from the schema has
no way to ask for `1050` and mean €10.50, so it asked for "amount in minor
units" and printed the real figure as a caption underneath. That is not a form
anyone should be handed, and no amount of renderer work fixes it while the
number on the wire is not the number a person says.

**2 — Precision is checked against the currency.** An amount may not be more
precise than its currency: `10.555 EUR` is not an amount of euros and `10.5 JPY`
is not an amount of yen. `Money.make` rounds to what the currency holds (half
away from zero); `Money.schema` refuses an over-precise amount, because by the
time a value is being parsed the rounding decision belonged to whoever produced
it. `validate` is derived from `round` — an amount is valid exactly when
rounding changes nothing — so the checker and the normaliser cannot drift.

The check sits on the *record*, not on the amount field: how precise an amount
may be is not a property of the number. That placement was previously impossible
— sury 11-alpha miscompiled a refinement wrapping a record schema, which is why
the old wholeness check sat on the field. Re-tested against 11.0.0-rc.2: fixed,
parse and serialize both work, and the JSON Schema derivation still sees through
to the properties (`SuryToJsonSchemaTest`'s Money block is the evidence).

**3 — `ofMajor` / `toMajor` are gone; `ofMinor` / `toMinor` replace them.** The
conversion did not disappear, it changed direction. A payment gateway and a
supplier feed count in minor units, so the scale is still written down in exactly
one place — and it is still read off the currency, so it is right for JPY (×1)
without anyone remembering that JPY is special. The hybrid example's supplier
feed is the live case: it sends `8990` and the domain stores `89.90`.

**4 — `Currency` admits ten codes.** AUD, CAD, CHF, CNY, EUR, GBP, JPY, NOK,
SEK, USD — the five most-traded worldwide, the two other majors a global shop
meets, and the three European currencies outside the euro that matter most.

The original argument for all 165 was that a curated list is "wrong the first
time an application needs a currency nobody listed — a compile error in someone
else's domain, fixable only by a framework release." That risk is real and it is
now bought back differently: **every dormant code is still in the generated
file, commented, in each of the four blocks that mentions one.** Admitting one
is uncommenting four lines, or adding it to `active` in the generator and
regenerating. Nobody waits for a release and nobody re-reads the standard.

What the curation buys is the thing 165 constructors cost: a currency picker
that a person can actually use. JPY stays in the set for a second reason — it is
the only admitted code with no decimal place, so it is what keeps `exponent`
load-bearing rather than a synonym for "two".

**5 — The generator is ReScript.** `scripts/generate-currency.mjs` became
[`scripts/GenerateCurrency.res`](../../scripts/GenerateCurrency.res), beside
`CheckGraphqlContract.res` and `CheckLifecycleModel.res` where this repo's
tooling lives, and the ISO table moved with it. `pnpm run generate:currency`
from the repo root.

## What this breaks

**Stored events do not migrate.** A log written before this change holds
`{"amount": 1050, "currency": "EUR"}` and will now decode as €1050.00 — a
hundredfold error that parses cleanly. There is no upcaster here: a local or
demo log is discarded and reseeded, and a log that has to survive needs one
written before the change is deployed.

**A stored currency outside the ten no longer decodes.** Same remedy: admit it
in the generator, or migrate the data.

## What a consumer of the `money` semantic has to do

The wire shape does not change — `{"amount", "currency"}`, the currency still an
enum of the admitted codes — so a renderer keying on the shape keeps working.
Two things it must stop doing: dividing the amount by the currency's scale
before displaying it, and asking for minor units on entry.

An entry control now owes the amount the currency's own decimal count. The
better place to enforce that is the keystroke — a decimal the currency has no
room for should never be typeable — rather than a round applied after the fact,
which changes a figure someone entered in full without telling them. `schema`
refuses an over-precise amount either way, so a client that posts one gets a
parse error rather than a quietly adjusted value.

The decimal count is available client-side from
`Intl.NumberFormat(…).resolvedOptions()`, which reads the same ISO table
`Currency.exponent` is generated from, reached from the other end; nothing needs
to import a table to agree with this one.
