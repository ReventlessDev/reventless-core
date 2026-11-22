/**
An amount of money: what people say, `{"amount": 0.45, "currency": "EUR"}`, wherever it is
written down, and inside a value a whole number of the currency's minor units, `minorUnits`,
so it is summed exactly.

## Money is what people say

An event, a view's row, a GraphQL argument and result, a webhook body and an MCP tool's input
all hold money as people say it: 0.45 EUR is forty-five cents. `schema` converts at every decode
and encode, so no edge converts on its own, and *amount* means one thing everywhere a person or
another system reads it. An amount with more decimals than its currency has is refused when it
is decoded: €0.455 is no amount, and rounding it would change what the sender meant without
telling them.

## Why the currency travels with the number

A minor unit is currency-dependent — ISO 4217 gives EUR two decimal places, **JPY
zero** and TND three — so a bare `1000` minor units is €10.00 or ¥1000 or 1.000 TND,
and there is no way to tell which. It cannot be rendered, compared, summed or
sanity-checked without knowing. The currency is part of the number's meaning, not
metadata beside it.

The alternative considered and rejected was a branded `amount` scalar with the
currency held once on the aggregate. Its appeal is real: mixing currencies
becomes unrepresentable rather than merely checkable. But it only works while
every amount an aggregate touches shares one currency, and the moment one does
not, the information needed to notice has already been deleted. `add` checks
instead — see below.

## Why whole minor units inside

`0.1 +. 0.2` is not `0.3`, and money is summed. Inside a value, minor units keep
every amount an exact integer, so addition is exact and equality means what it
says. Holding the decimal a person types in the value was tried and reverted:
every sum outside `add` became a float sum, and the failure is a figure that is a
cent out and looks entirely plausible.

Saying the amount as people do on the wire does not bring that back. A value is
encoded from whole minor units by one division, JSON prints the shortest decimal
that reads back as the same `float`, and decoding multiplies, snaps a hair's
error and checks the result is whole: every whole number of minor units below
2^53 comes back as itself, and no sum ever runs on the said amount.

## Why `float` for a whole number

Because ReScript's `int` is int32, and sury enforces that — an `int` count caps
at 2,147,483,647 minor units, which is €21,474,836.47. A framework type that
cannot express a €22M total is not a money type. `float` is exact for every
integer below 2^53 (about €90 trillion in cents), and the wholeness that `int`
would have given for free is checked in `schema`.

## How a field declares it

Unlike the branded scalars, this is not an `@s.matches` refinement — the field's
declared type *is* `Money.t`, and sury-ppx resolves it to this module's `schema`:

```rescript
@schema type state = {
  productId: string,
  price: Reventless.Money.t,
}
```

which serializes as `{"amount": 10.5, "currency": "EUR"}` for €10.50.

**That is a structural change to the field.** Retyping an existing `price: float`
rewrites the wire shape, so stored events no longer decode and projections must
be rebuilt. Retyping a field in a log that has to survive needs an upcaster
first; a log that can be discarded can take it today.
*/
/**
Validate a count of minor units, saying why when it is not one.

The single definition of what a count may hold; `minorUnitsSchema` is derived
from it rather than hand-rolling a second check, the rule `StorageRef`
established.
*/
let validateMinorUnits = (minorUnits: float): result<float, string> =>
  if !Float.isFinite(minorUnits) {
    Error(`a count of minor units must be finite, got ${Float.toString(minorUnits)}`)
  } else if minorUnits !== Math.trunc(minorUnits) {
    Error(
      `a count of minor units is whole, got ${Float.toString(
          minorUnits,
        )}. ` ++ `There is no such thing as a fraction of the smallest unit — an amount as people say it is made with Money.make.`,
    )
  } else {
    Ok(minorUnits)
  }

let minorUnitsSchema: S.t<float> = S.float->S.refine(minorUnits =>
  switch validateMinorUnits(minorUnits) {
  | Ok(_) => true
  | Error(_) => false
  }
, ~error="expected a whole number of minor units")

/** Money inside a value: the currency's minor units, counted. */
type t = {
  /** Whole minor units of `currency` — 1050 is €10.50, ¥1050 or 1.050 TND
      depending on which. Negative counts are allowed: a refund is money. */
  minorUnits: float,
  currency: Currency.t,
}

/** Ten to the power of the currency's decimal count — the factor between an
    amount as people say it and the minor units it is. */
let scale = (currency: Currency.t): float =>
  Math.pow(10.0, ~exp=Int.toFloat(Currency.exponent(currency)))

/** An amount as people say it, counted in minor units: `None` where it has more
    decimals than the currency. A decimal is a hair off in binary (0.29 × 100 is
    28.999999999999996), so the amount is rounded to minor units, and it has no
    more decimals than the currency exactly when saying that count again gives
    back the same amount. */
let counted = (~amount: float, ~currency: Currency.t): option<float> =>
  if !Float.isFinite(amount) {
    None
  } else {
    let factor = scale(currency)
    let minorUnits = Math.round(amount *. factor)
    minorUnits /. factor == amount ? Some(minorUnits) : None
  }

/** What `amount` is, in words: the description an API writes on it. */
let amountDescription = "The amount of money as people say it: 0.45 EUR is forty-five cents. At most as many decimals as the currency has."

/** Whether a semantic is money: plain money, or a price per a quantity's unit, which is money
    and carries its own semantic in place of `money` (a schema holds one). */
let isMoney = (s: Semantic.t) => s.id == Semantic.Id.money || s.id == Semantic.Id.pricePerUnit

/** Money as it is written down: the amount as people say it. */
type said = {amount: float, currency: Currency.t}

let saidSchema: S.t<said> = S.schema(s => {
  amount: s.matches(S.float),
  currency: s.matches(Currency.schema),
})

let countedSchema: S.t<t> = S.schema(s => {
  minorUnits: s.matches(minorUnitsSchema),
  currency: s.matches(Currency.schema),
})

/** The sury schema for a money field, carrying the `money` semantic: written down as people
    say it (`{"amount": 0.45, "currency": "EUR"}`), held as minor units. Both shapes are
    declared, so sury sees what each side holds and an absent optional value never reaches the
    conversion. */
let schema: S.t<t> =
  saidSchema
  ->S.to(
    countedSchema,
    ~custom={
      decode: Sync(
        (m: said): t =>
          switch counted(~amount=m.amount, ~currency=m.currency) {
          | Some(minorUnits) => {minorUnits, currency: m.currency}
          | None =>
            JsError.throwWithMessage(
              `${Float.toString(m.amount)} has more decimals than ${Currency.toString(
                  m.currency,
                )}'s ${Int.toString(Currency.exponent(m.currency))}`,
            )
          },
      ),
      encode: Sync(
        (m: t): said => {amount: m.minorUnits /. scale(m.currency), currency: m.currency},
      ),
    },
  )
  ->Semantic.mark(~id=Semantic.Id.money)

/**
Money as people say it: `Money.make(~amount=10.5, ~currency=EUR)` is €10.50.

Counted in the currency's own minor units, so it is correct for JPY and TND
too. An amount with more decimals than the currency has is rounded half away
from zero, in both directions: `Math.round` alone rounds half toward positive
infinity, so `-2.5` would come back `-2` and a refund would round the other way
from the charge it reverses. Code that computes a price rounds here, once; an
amount someone sent is refused instead, by `schema`.
*/
let make = (~amount: float, ~currency: Currency.t): t => {
  let scaled = amount *. scale(currency)
  {minorUnits: scaled < 0.0 ? -.Math.round(-.scaled) : Math.round(scaled), currency}
}

/** Money already counted in minor units: `ofMinorUnits(~minorUnits=1050., ~currency=EUR)` is
    €10.50. */
let ofMinorUnits = (~minorUnits: float, ~currency: Currency.t): t => {minorUnits, currency}

/** The amount as people say it — what a form shows, and what a chart axis or an
    average needs. Lossy by nature: the result is a float again, so it is an
    output, not something to compute a balance in. */
let amount = (m: t): float => m.minorUnits /. scale(m.currency)

/** Nothing, in a currency. A zero still has a currency — "no money" and "no
    euros" are different claims, and only the second one adds to a total. */
let zero = (~currency: Currency.t): t => {minorUnits: 0.0, currency}

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
  let negative = m.minorUnits < 0.0
  let digits = Float.toString(negative ? -.m.minorUnits : m.minorUnits)
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
    ? Ok({minorUnits: a.minorUnits +. b.minorUnits, currency: a.currency})
    : Error(
        `cannot add ${format(b)} to ${format(
            a,
          )}: they are different currencies. ` ++ `Converting between them needs a rate, which is not something an amount carries.`,
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
is why a call site should not write `minorUnits *. Int.toFloat(quantity)` itself.

A rate is the other operation, and deliberately not this one. 15% of €10.50 is
€8.925, which is not an amount of euros in the first place — so applying a rate
is a rounding decision the domain has to state, through `amount`, the
arithmetic, and `make` back, with the rounding visible where someone chose it.

Refuses a product past the range where a `float` is an exact integer. Handing
back an inexact amount is the failure the wholeness check exists to prevent, and
it would not do to introduce it here.
*/
let times = (m: t, ~by: int): result<t, string> => {
  let product = m.minorUnits *. Int.toFloat(by)
  Math.abs(product) <= maxSafeInteger
    ? Ok({minorUnits: product, currency: m.currency})
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
      `cannot split ${format(m)} into ${Int.toString(
          into,
        )} parts: ` ++ `a split is into at least one part.`,
    )
  } else {
    let parts = Int.toFloat(into)
    // Truncated toward zero, so the remainder carries the sign of the amount and
    // every part stays on the same side of zero as the whole it came from.
    let share = Math.trunc(m.minorUnits /. parts)
    // Taken from the share actually used rather than from the ideal one, which
    // is what makes the parts add back up by construction.
    let remainder = m.minorUnits -. share *. parts
    let step = remainder < 0.0 ? -1.0 : 1.0
    let extra = Math.abs(remainder)
    Ok(
      Array.fromInitializer(~length=into, i => {
        minorUnits: share +. (Int.toFloat(i) < extra ? step : 0.0),
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
  | _ =>
    Some(
      amounts->Array.reduce(Ok(zero(~currency=(amounts->Array.getUnsafe(0)).currency)), (acc, m) =>
        acc->Result.flatMap(total => add(total, m))
      ),
    )
  }
