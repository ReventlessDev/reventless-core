# Ten currencies, and where minor units stop

Status: **done**.

Amends [semantic-money-and-currency.md](semantic-money-and-currency.md) in one
place and *defends* it in another. `Currency` now admits ten codes instead of
165. `Money.t.amount` is still a whole number of minor units — that was changed
and changed back inside this piece of work, and the round trip is the useful part
of the record.

## Ten currencies

AUD, CAD, CHF, CNY, EUR, GBP, JPY, NOK, SEK, USD — the five most-traded
worldwide, the two other majors a global shop meets, and the three European
currencies outside the euro that matter most.

The original argument for all 165 was that a curated list is "wrong the first
time an application needs a currency nobody listed — a compile error in someone
else's domain, fixable only by a framework release." That risk is real and it is
now bought back differently: **every dormant code is still in the generated file,
commented, in each of the four blocks that mentions one.** Admitting one is
uncommenting four lines, or adding it to `active` in the generator and
regenerating. Nobody waits for a release and nobody re-reads the standard.

What the curation buys is the thing 165 constructors cost: a currency picker a
person can use. JPY stays for a second reason — it is the only admitted code with
no decimal place, so it is what keeps `exponent` load-bearing rather than a
synonym for "two".

The generator moved to [`scripts/GenerateCurrency.res`](../../scripts/GenerateCurrency.res),
beside `CheckGraphqlContract.res` and `CheckLifecycleModel.res` where this repo's
tooling lives, with the ISO table alongside it. `pnpm run generate:currency` from
the repo root.

## The amount stays in minor units — the round trip

The complaint that started this was concrete and correct: a generated form asked
for "amount in minor units" and printed the real figure as a caption underneath,
because a form built from the schema had no other way to ask for `1050` and mean
€10.50. Nobody should be handed that.

The first answer was to change the type: hold the decimal a person types, check
it against the currency's precision, keep exactness by scaling inside `add`. It
worked, and it was reverted, because the guarantee it kept was narrower than it
looked:

- `add` and `sum` were exact, but nothing else was. Any code touching `.amount`
  with `+.` — a read side totalling a page of rows, a client averaging — is
  summing decimals, and the failure mode is a figure one cent out that looks
  entirely plausible. The invariant became "everyone remembers to use `Money.add`",
  which is not an invariant.
- Binary floating point is not what money is counted in. Professional systems use
  either integer minor units (Stripe and most payment APIs) or an exact decimal
  type (`BigDecimal`, `NUMERIC`, `decimal`), usually travelling as a string so a
  JSON number never becomes a double. A `float` holding an exact decimal is fine
  until something does arithmetic on it, and a framework type cannot promise that
  on behalf of everyone downstream.

**The form complaint was a presentation problem all along**, and the fix belongs
where the problem is: `ofMajor`/`toMajor` are the boundary, and a form converts
through them the way a supplier feed already did. Nothing a person sees or types
is in minor units; nothing stored or summed is not.

What survived from the attempt, because it was right independently:

- `ofMajor` rounds **half away from zero**. It used to use `Math.round`, which
  rounds half toward positive infinity, so `-2.5` came back `-2` and a refund
  rounded the other way from the charge it reversed.
- `scale` is named once rather than spelled `Math.pow` in two places.
- The note in `amountSchema` about placement is now accurate: sury 11.0.0-rc.2
  compiles a record-level refinement correctly (11-alpha hoisted the result
  object above the field reads and threw `Cannot access 'v0' before
  initialization`), so the field-level check is a choice rather than a
  workaround — and it is the right one, because wholeness needs nothing but the
  number.

## The two operations that were missing

Exact addition is only half of what money does. Both of these were written at
call sites or not at all, which is where the rounding mistakes live.

**`times(m, ~by: int)`** — a line item's unit price by its quantity. `~by` is an
`int` on purpose: the operand is a count, not a rate, and whole minor units times
a whole count needs no rounding decision. Refuses a product past 2^53, since an
inexact amount is the one thing the wholeness check exists to keep out. A *rate*
is the other operation and deliberately not this one — 15% of €10.50 is €8.925,
which is not an amount of euros, so applying one is a decision the domain states
rather than an arithmetic the type performs.

**`allocate(m, ~into: int)`** — a split whose parts add back up. Dividing and
rounding each part on its own loses or invents a unit: €10.00 into three is €3.33
three times, which is €9.99. The remainder is handed to the earliest parts
instead, so €10.00 into three is €3.34, €3.33, €3.33. Which parts get it is
arbitrary but has to be *decided*; a caller wanting it elsewhere reorders the
result, and a caller wanting uneven shares wants a split by ratio, which is a
different function and not yet one.

## What this breaks

**A stored currency outside the ten no longer decodes.** Admit it in the
generator, or migrate the data. Amounts are unaffected — they are in the units
they always were.

## What a consumer of the `money` semantic has to do

Nothing changed in the wire shape: `{"amount", "currency"}`, amount in minor
units, currency an enum of the admitted codes.

What did change is the standard this sets for a control over the semantic. It
must not show or accept minor units. It converts at its own edge, and it should
enforce the currency's precision by refusing a decimal the currency has no room
for rather than rounding one away after the fact — rounding a figure someone
typed in full changes it under them with no moment at which they are told. The
decimal count is available client-side from
`Intl.NumberFormat(…).resolvedOptions()`, which reads the same ISO table
`Currency.exponent` is generated from, reached from the other end.
