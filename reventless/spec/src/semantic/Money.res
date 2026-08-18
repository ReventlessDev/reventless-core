/**
An amount of money: a whole number of a currency's minor units, and the currency
those units belong to.

## Why the currency travels with the number

A minor unit is currency-dependent — ISO 4217 gives EUR two decimal places, **JPY
zero** and **TND three** — so a bare `1000` is €10.00 or ¥1000 or 1.000 TND, and
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

/** The amount's own schema. The check sits on the field rather than on the pair
    because wholeness is a property of the amount — and because sury 11-alpha
    miscompiles a refinement wrapping a *record* schema (it hoists the result
    object above the field reads, so both parse and serialize throw
    `Cannot access 'v0' before initialization`). Refining the field is both the
    honest placement and the one that works. */
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

/**
Convert a major-unit decimal (`10.5`) into minor units (`1050`), using the
currency's own exponent.

This is the one place a decimal is allowed to become money, and it is here rather
than at each call site precisely so that `*. 100.0` is written once and is
correct for JPY and TND — where it would be `*. 1.0` and `*. 1000.0`.

Rounds half away from zero (`10.005` EUR → `1001`), which is what a reader
expects of a price. That is a *boundary conversion* and not an arithmetic
policy: the half-even question that FX and tax rounding turn on is a separate
decision, and nothing here forecloses it.
*/
let ofMajor = (~amount: float, ~currency: Currency.t): t => {
  let scale = Math.pow(10.0, ~exp=Int.toFloat(Currency.exponent(currency)))
  {amount: Math.round(amount *. scale), currency}
}

/** The amount as a major-unit decimal — for charts, averages and anything that
    has to be a number rather than money. Lossy by nature: the result is a float
    again, so it is an output, not something to compute a balance in. */
let toMajor = (m: t): float =>
  m.amount /. Math.pow(10.0, ~exp=Int.toFloat(Currency.exponent(m.currency)))

/**
The amount as text: the decimal point placed by the currency's exponent, digits
grouped in threes, and the ISO code after it — `"1,234.50 EUR"`, `"1,000 JPY"`,
`"1.000 TND"`.

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
*/
let add = (a: t, b: t): result<t, string> =>
  a.currency == b.currency
    ? Ok({amount: a.amount +. b.amount, currency: a.currency})
    : Error(
        `cannot add ${format(b)} to ${format(a)}: they are different currencies. ` ++
        `Converting between them needs a rate, which is not something an amount carries.`,
      )

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
