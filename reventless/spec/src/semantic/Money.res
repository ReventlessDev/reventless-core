/**
An amount of money: a decimal amount carrying exactly the number of decimal
places its currency has, and the currency those decimals belong to.

## Why the currency travels with the number

How precise an amount may be is currency-dependent — ISO 4217 gives EUR two
decimal places, **JPY zero** and TND three — so `10.5` is a legal amount of euros
and not a legal amount of yen, and there is no way to tell which from the number
alone. Nor can it be rendered, compared, summed or sanity-checked without knowing.
The currency is part of the number's meaning, not metadata beside it.

The alternative considered and rejected was a branded `amount` scalar with the
currency held once on the aggregate. Its appeal is real: mixing currencies
becomes unrepresentable rather than merely checkable. But it only works while
every amount an aggregate touches shares one currency, and the moment one does
not, the information needed to notice has already been deleted. `add` checks
instead — see below.

## Why the amount is what a person types

`price` holds `10.5` for €10.50, not `1050`. The number in the field, the number
on the wire and the number in the log are one number, and reading any of them
needs no scale in the reader's head.

The earlier design stored whole minor units — `1050` — for exactness: `0.1 +. 0.2`
is not `0.3`, and money is summed. That reason was real and it is answered rather
than ignored. `add` scales to whole minor units, adds there and scales back, so
addition is still exact; what changed is that the scaling is an implementation
detail of arithmetic rather than a tax on every form, every fixture and every
person reading a price off the wire.

## Why `float`

Because ReScript's `int` is int32, and sury enforces that — and because an amount
has a fractional part in all but a handful of currencies, which an integer type
cannot hold at all without reintroducing the scale this type exists to remove.
`float` is exact for every value with at most a currency's decimals up to about
2^53 minor units, which is roughly €90 trillion.

## Precision is checked, not assumed

An amount may not be more precise than its currency: `10.555 EUR` is not an
amount of euros, and `10.5 JPY` is not an amount of yen. `make` rounds an
over-precise amount to what the currency can hold; `schema` refuses one, because
by the time a value is being parsed the rounding decision belonged to whoever
produced it.

## How a field declares it

Unlike the branded scalars, this is not an `@s.matches` refinement — the field's
declared type *is* `Money.t`, and sury-ppx resolves it to this module's `schema`:

```rescript
@schema type state = {
  productId: string,
  price: Reventless.Money.t,
}
```

which serializes as `{"amount": 10.5, "currency": "EUR"}`.

**That is a structural change to the field.** Retyping an existing `price: float`
rewrites the wire shape, so stored events no longer decode and projections must
be rebuilt. Retyping a field in a log that has to survive needs an upcaster
first; a log that can be discarded can take it today.
*/

/** Ten to the power of the currency's decimal count — the factor between an
    amount and the whole number of minor units it is. Named because three things
    below need it and none of them should spell out `Math.pow` again. */
let scale = (currency: Currency.t): float =>
  Math.pow(10.0, ~exp=Int.toFloat(Currency.exponent(currency)))

/**
Round an amount to the decimals its currency has, half away from zero.

`Math.round` alone would not do: it rounds half toward positive infinity, so
`-2.5` comes back `-2` and a refund would round the other way from the charge it
reverses. Half away from zero is what a reader expects of a price, and it is the
same in both directions.

This is a *boundary conversion* and not an arithmetic policy: the half-even
question that FX and tax rounding turn on is a separate decision, and nothing
here forecloses it.
*/
let round = (~amount: float, ~currency: Currency.t): float => {
  let factor = scale(currency)
  let scaled = amount *. factor
  (scaled < 0.0 ? -.Math.round(-.scaled) : Math.round(scaled)) /. factor
}

/**
Validate an amount against its currency, saying why when it does not hold.

The single definition of what an amount may be, derived from `round` rather than
re-stating it: an amount is valid exactly when rounding it changes nothing. A
second spelling of "at most N decimals" is how a checker and a normaliser drift
apart, and `schema` is built from this one.
*/
let validate = (~amount: float, ~currency: Currency.t): result<float, string> =>
  if !Float.isFinite(amount) {
    Error(`an amount must be a finite number, got ${Float.toString(amount)}`)
  } else if round(~amount, ~currency) !== amount {
    let places = Currency.exponent(currency)
    Error(
      `${Currency.toString(currency)} has ` ++
      (places == 0
        ? `no decimal places, so ${Float.toString(amount)} is not an amount of it`
        : `${Int.toString(places)} decimal places, so ${Float.toString(amount)} is ` ++
          `more precise than one. Money.make rounds an amount to what its currency holds.`),
    )
  } else {
    Ok(amount)
  }

@schema
type t = {
  /** The amount, in the currency's own units and to its own precision — `10.5`
      is €10.50, `1000` is ¥1000. Negative amounts are allowed: a refund is
      money. */
  amount: float,
  currency: Currency.t,
}

/** The sury schema for a money field: the shape sury-ppx derived above, the
    precision rule checked against the currency beside it, and the semantic
    marker the shape cannot carry.

    The check sits on the record rather than on the amount field because it needs
    both halves — how precise an amount may be is not a property of the number.
    Shadows the ppx-derived `schema`. */
let schema: S.t<t> =
  schema
  ->S.refine(
    m =>
      switch validate(~amount=m.amount, ~currency=m.currency) {
      | Ok(_) => true
      | Error(_) => false
      },
    ~error="expected an amount its currency can hold",
  )
  ->Semantic.mark(~id=Semantic.Id.money)

/** An amount in a currency, rounded to what that currency can hold. Rounding
    here rather than refusing is what makes this total: every construction site
    would otherwise have to decide, and they would decide differently. */
let make = (~amount: float, ~currency: Currency.t): t => {
  amount: round(~amount, ~currency),
  currency,
}

/** Nothing, in a currency. A zero still has a currency — "no money" and "no
    euros" are different claims, and only the second one adds to a total. */
let zero = (~currency: Currency.t): t => {amount: 0.0, currency}

/**
An amount counted in a currency's minor units — what a payment gateway quotes and
what a supplier feed usually sends.

Kept because those systems exist, not because the domain thinks in minor units:
this is the one place the scale is written down, and it is correct for JPY
(`×1`) and TND (`×1000`) where a hand-written `/. 100.0` at the call site would
be wrong for both.
*/
let ofMinor = (~units: float, ~currency: Currency.t): t => {
  amount: units /. scale(currency),
  currency,
}

/** The amount as a whole number of minor units, for talking back to a system
    that counts in them. */
let toMinor = (m: t): float => Math.round(m.amount *. scale(m.currency))

/**
The amount as text: the currency's own decimals, digits grouped in threes, and
the ISO code after it — `"1,234.50 EUR"`, `"1,000 JPY"`.

Deliberately locale-independent, matching the rest of the framework's
formatters: the same value reads the same in every log line and every test. A
locale-aware, symbol-bearing rendering is the presentation layer's job, and it
has the currency code to do it with.
*/
let format = (m: t): string => {
  let negative = m.amount < 0.0
  let fixed = Float.toFixed(negative ? -.m.amount : m.amount, ~digits=Currency.exponent(m.currency))
  let parts = fixed->String.split(".")
  let whole = parts->Array.get(0)->Option.getOr("0")
  let fraction = parts->Array.get(1)
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
  switch fraction {
  | Some(f) => "." ++ f
  | None => ""
  } ++
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

The addition itself is done on whole minor units and scaled back, because `0.1
+. 0.2` is not `0.3` and money is summed. That is the exactness the old
minor-unit representation bought, kept here where it belongs — inside the
arithmetic — instead of being charged to everyone who reads or writes an amount.
*/
let add = (a: t, b: t): result<t, string> =>
  a.currency == b.currency
    ? {
        let factor = scale(a.currency)
        Ok({
          amount: (Math.round(a.amount *. factor) +. Math.round(b.amount *. factor)) /. factor,
          currency: a.currency,
        })
      }
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
