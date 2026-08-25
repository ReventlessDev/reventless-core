/**
An amount of money: a whole number of a currency's minor units, and the currency
those units belong to.

## Why the currency travels with the number

A minor unit is currency-dependent — ISO 4217 gives EUR two decimal places, **JPY
zero** and TND three — so a bare `1000` is €10.00 or ¥1000 or 1.000 TND, and
there is no way to tell which. It cannot be rendered, compared, summed or
sanity-checked without knowing. The currency is part of the number's meaning, not
metadata beside it.

The alternative considered and rejected was a branded `amount` scalar with the
currency held once on the aggregate. Its appeal is real: mixing currencies
becomes unrepresentable rather than merely checkable. But it only works while
every amount an aggregate touches shares one currency, and the moment one does
not, the information needed to notice has already been deleted. `add` checks
instead — see below.

## Why whole minor units and not a decimal major amount

`0.1 +. 0.2` is not `0.3`, and money is summed. Minor units keep every amount an
exact integer, so addition is exact and equality means what it says.

This was tried the other way — an amount holding the decimal a person types —
and reverted. What it bought was a readable log; what it cost was the guarantee.
Every sum outside `add` became a float sum, including the ones a read side does
over a page of rows, and the failure is a figure that is a cent out and looks
entirely plausible. Binary floating point is not what money is counted in, and
holding the exact value in a `float` only works while nothing does arithmetic on
it — which is not a property a framework type can promise on behalf of everyone
downstream.

**The complaint that prompted the attempt was real and is answered elsewhere.** A
form generated from this schema must not ask anyone for `1050`; it asks for
`10.50` and converts at its own boundary, with `ofMajor`/`toMajor` below. That is
a presentation concern, and this type had been letting it leak.

## Why `float` for a whole number

Because ReScript's `int` is int32, and sury enforces that — an `int` amount caps
at 2,147,483,647 minor units, which is €21,474,836.47. A framework type that
cannot express a €22M total is not a money type. `float` is exact for every
integer below 2^53 (about €90 trillion in cents), and the wholeness that `int`
would have given for free is recovered by checking it in `schema`.

This is the same correction `Bytes` already made for the same reason, and the
wire form is identical either way: both are JSON numbers.

## How a field declares it

Unlike the branded scalars, this is not an `@s.matches` refinement — the field's
declared type *is* `Money.t`, and sury-ppx resolves it to this module's `schema`:

```rescript
@schema type state = {
  productId: string,
  price: Reventless.Money.t,
}
```

which serializes as `{"amount": 1000, "currency": "EUR"}`.

**That is a structural change to the field.** Retyping an existing `price: float`
rewrites the wire shape, so stored events no longer decode and projections must
be rebuilt. Retyping a field in a log that has to survive needs an upcaster
first; a log that can be discarded can take it today.
*/

/**
Validate a minor-unit amount, saying why when it is not one.

The single definition of what an amount may hold; `amountSchema` is derived from
it rather than hand-rolling a second check, the rule `StorageRef` established.
*/
let validateAmount = (amount: float): result<float, string> =>
  if !Float.isFinite(amount) {
    Error(`an amount must be a finite number of minor units, got ${Float.toString(amount)}`)
  } else if amount !== Math.trunc(amount) {
    Error(
      `an amount is a whole number of a currency's minor units, got ` ++
      `${Float.toString(amount)}. There is no such thing as a fraction of the ` ++
      `smallest unit — a major amount converts with Money.ofMajor.`,
    )
  } else {
    Ok(amount)
  }

/** The amount's own schema.

    The check sits on the field rather than on the pair because wholeness is a
    property of the amount: it does not need the currency, and a rule placed
    where it needs nothing else is a rule that cannot be read wrong. (A
    record-level refinement is available — sury 11.0.0-rc.2 compiles one
    correctly, where 11-alpha hoisted the result object above the field reads and
    threw `Cannot access 'v0' before initialization` — it is simply not what this
    check wants.) */
let amountSchema: S.t<float> =
  S.float->S.refine(
    amount =>
      switch validateAmount(amount) {
      | Ok(_) => true
      | Error(_) => false
      },
    ~error="expected a monetary amount",
  )

@schema
type t = {
  /** Whole minor units of `currency` — 1000 is €10.00, ¥1000 or 1.000 TND
      depending on which. Negative amounts are allowed: a refund is money. */
  amount: @s.matches(amountSchema) float,
  currency: Currency.t,
}

/** The sury schema for a money field, carrying the `money` semantic.

    Shadows the schema sury-ppx derived from the type above: the derived one is
    the shape, and this adds the marker the shape cannot carry. */
let schema: S.t<t> = schema->Semantic.mark(~id=Semantic.Id.money)

/** An amount already counted in minor units. */
let make = (~amount: float, ~currency: Currency.t): t => {amount, currency}

/** Nothing, in a currency. A zero still has a currency — "no money" and "no
    euros" are different claims, and only the second one adds to a total. */
let zero = (~currency: Currency.t): t => {amount: 0.0, currency}

/** Ten to the power of the currency's decimal count — the factor between a major
    amount and the minor units it is. Named because the two conversions below
    both need it and neither should spell out `Math.pow` again. */
let scale = (currency: Currency.t): float =>
  Math.pow(10.0, ~exp=Int.toFloat(Currency.exponent(currency)))

/**
Convert a major-unit decimal (`10.5`) into minor units (`1050`), using the
currency's own exponent.

This is the one place a decimal is allowed to become money, and it is here rather
than at each call site precisely so that `*. 100.0` is written once and is
correct for JPY and TND — where it would be `*. 1.0` and `*. 1000.0`. It is what
a form, a supplier feed or any other boundary that speaks in decimals converts
through.

Rounds half away from zero, in both directions: `Math.round` alone rounds half
toward positive infinity, so `-2.5` would come back `-2` and a refund would round
the other way from the charge it reverses. That is a *boundary conversion* and
not an arithmetic policy: the half-even question that FX and tax rounding turn on
is a separate decision, and nothing here forecloses it.
*/
let ofMajor = (~amount: float, ~currency: Currency.t): t => {
  let scaled = amount *. scale(currency)
  {amount: scaled < 0.0 ? -.Math.round(-.scaled) : Math.round(scaled), currency}
}

/** The amount as a major-unit decimal — what a form shows, and what a chart axis
    or an average needs. Lossy by nature: the result is a float again, so it is an
    output, not something to compute a balance in. */
let toMajor = (m: t): float => m.amount /. scale(m.currency)

/**
The amount as text: the decimal point placed by the currency's exponent, digits
grouped in threes, and the ISO code after it — `"1,234.50 EUR"`, `"1,000 JPY"`.

Deliberately locale-independent, matching the rest of the framework's
formatters: the same value reads the same in every log line and every test. A
locale-aware, symbol-bearing rendering is the presentation layer's job, and it
has the currency code to do it with.
*/
let format = (m: t): string => {
  let exponent = Currency.exponent(m.currency)
  let negative = m.amount < 0.0
  let digits = Float.toString(negative ? -.m.amount : m.amount)
  // Pad so there is always at least one digit left of the point: 5 minor units
  // of EUR is "0.05", not ".05".
  let padded = digits->String.padStart(exponent + 1, "0")
  let split = String.length(padded) - exponent
  let whole = padded->String.slice(~start=0, ~end=split)
  let fraction = padded->String.slice(~start=split, ~end=String.length(padded))
  let rec group = (s: string): string => {
    let length = String.length(s)
    length <= 3
      ? s
      : group(s->String.slice(~start=0, ~end=length - 3)) ++
        "," ++
        s->String.slice(~start=length - 3, ~end=length)
  }
  (negative ? "-" : "") ++
  group(whole) ++
  (exponent == 0 ? "" : "." ++ fraction) ++
  " " ++
  Currency.toString(m.currency)
}

/**
Add two amounts, refusing to add across currencies.

This is §15.1's second rider made executable. The genuine appeal of the
branded-scalar shape was that mixing currencies could not be written at all; the
answer is to *check* it rather than to delete the information that makes checking
possible. An aggregate that must hold one currency rejects a line item in
another — a decider's concern, and one it can now actually express.

The addition itself is integer addition, because both amounts are whole minor
units. That is the whole reason they are.
*/
let add = (a: t, b: t): result<t, string> =>
  a.currency == b.currency
    ? Ok({amount: a.amount +. b.amount, currency: a.currency})
    : Error(
        `cannot add ${format(b)} to ${format(a)}: they are different currencies. ` ++
        `Converting between them needs a rate, which is not something an amount carries.`,
      )

/** The largest whole number a `float` holds exactly, 2^53 - 1. Bound here
    because `Float.Constants` does not carry it, and named because it is the
    range every guarantee in this module is stated over. */
@val @scope("Number") external maxSafeInteger: float = "MAX_SAFE_INTEGER"

/**
Multiply an amount by a count — a line item's unit price by its quantity.

`~by` is an `int` because the operand is a *count* and not a rate: three of
something, not 15% of something. Whole minor units times a whole count is
whole-number arithmetic, so the result is an exact amount and no rounding
question arises at all. That is the property this function exists to keep, and it
is why a call site should not write `amount *. Int.toFloat(quantity)` itself.

A rate is the other operation, and deliberately not this one. 15% of €10.50 is
€8.925, which is not an amount of euros in the first place — so applying a rate
is a rounding decision the domain has to state, through `toMajor`, the
arithmetic, and `ofMajor` back, with the rounding visible where someone chose it.

Refuses a product past the range where a `float` is an exact integer. Handing
back an inexact amount is the failure the wholeness check exists to prevent, and
it would not do to introduce it here.
*/
let times = (m: t, ~by: int): result<t, string> => {
  let product = m.amount *. Int.toFloat(by)
  Math.abs(product) <= maxSafeInteger
    ? Ok({amount: product, currency: m.currency})
    : Error(
        `cannot multiply ${format(m)} by ${Int.toString(by)}: the result is past the ` ++
        `largest amount that stays exact, ${Float.toString(maxSafeInteger)} minor units.`,
      )
}

/**
Split an amount into `into` parts that add back up to it.

The last minor unit has to go somewhere. Dividing and rounding each part on its
own loses or invents one — €10.00 into three is €3.33 three times, which is
€9.99 — so the remainder is handed out instead: the first parts get one minor
unit more than the rest. €10.00 into three is €3.34, €3.33, €3.33, and those add
up to €10.00.

*Which* parts get the extra unit is arbitrary, but it has to be decided rather
than left to a rounding mode, and "the earliest" is the decision here. A caller
that needs it somewhere else — the largest share, the payer's — reorders what it
gets back. A caller that needs uneven shares wants a split by ratio, which is a
different function and not this one.

A negative amount splits away from zero the same way: -€10.00 into three is
-€3.34, -€3.33, -€3.33. A refund divides like a charge.
*/
let allocate = (m: t, ~into: int): result<array<t>, string> =>
  if into <= 0 {
    Error(
      `cannot split ${format(m)} into ${Int.toString(into)} parts: ` ++
      `a split is into at least one part.`,
    )
  } else {
    let parts = Int.toFloat(into)
    // Truncated toward zero, so the remainder carries the sign of the amount and
    // every part stays on the same side of zero as the whole it came from.
    let share = Math.trunc(m.amount /. parts)
    // Taken from the share actually used rather than from the ideal one, which
    // is what makes the parts add back up by construction.
    let remainder = m.amount -. share *. parts
    let step = remainder < 0.0 ? -1.0 : 1.0
    let extra = Math.abs(remainder)
    Ok(
      Array.fromInitializer(~length=into, i => {
        amount: share +. (Int.toFloat(i) < extra ? step : 0.0),
        currency: m.currency,
      }),
    )
  }

/** Add a run of amounts, refusing at the first currency that does not match the
    first amount's. `None` for an empty run — the sum of no amounts has no
    currency to be in. */
let sum = (amounts: array<t>): option<result<t, string>> =>
  switch amounts {
  | [] => None
  | _ => Some(amounts->Array.reduce(Ok(zero(~currency=(amounts->Array.getUnsafe(0)).currency)), (
      acc,
      m,
    ) => acc->Result.flatMap(total => add(total, m))))
  }
