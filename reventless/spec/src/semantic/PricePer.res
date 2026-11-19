/**
Money per a quantity's unit: 39 ct per kWh.

The value is `Money.t`, with its currency and whole minor units; only the
field's schema says *per kWh*, as the semantic `pricePerUnit` with the unit as
its detail. A price's currency never converts by a factor and its unit does, so
the price stays money and every rule of money keeps holding.

@example
```rescript
@schema type state = {
  siteId: string,
  price: @s.matches(Reventless.PricePer.unit(Reventless.Energy.kilowattHour)) Reventless.Money.t,
}
```

Retyping a `price: float` as this changes what is stored, as retyping it as
`Money.t` does: see `Money`.
*/
type t = Money.t

/** The schema of a field holding money per one unit of a quantity. */
let unit = (per: S.t<Quantity.t>): S.t<t> => {
  let (q, code) = Quantity.unitOfSchema(per)
  Money.schema
  ->Semantic.mark(~id=Semantic.Id.pricePerUnit, ~payload=PerUnit({quantity: q.name, unit: code}))
  ->S.Metadata.set(~id=Quantity.defId, q)
}

// A product of a whole amount and a converted quantity lands a hair off where it
// should be exact (0.0124 MWh at 39,000 ct is 483.59999…). Snapped to a millionth
// of a minor unit before rounding, so a half cent is a half cent; past a billion
// minor units a float holds no such fraction anyway.
let snap = (x: float): float => Math.abs(x) < 1e9 ? Math.round(x *. 1e6) /. 1e6 : x

/** Half away from zero, as an invoice is checked: 2.5 ct is 3 ct, -2.5 ct is -3. */
let roundHalfAway = (x: float): float => x < 0.0 ? -.Math.round(-.x) : Math.round(x)

/**
Charge a quantity at a price: 12.4 kWh at 39 ct per kWh is 4.84 €.

Converts the quantity into the price's unit, multiplies, and rounds once, to
the currency's minor unit, half away from zero. Rounding a converted price and
then the product would drift by a cent; one rounding is the one a person
checking the invoice can redo. A quantity of another kind than the price's is
refused, as is a charge past the amounts a float holds exactly.
*/
let charge = (price: t, ~per: S.t<Quantity.t>, quantity: Quantity.t, ~in_: S.t<Quantity.t>): result<
  Money.t,
  string,
> => {
  let (priceQuantity, priceUnit) = Quantity.unitOfSchema(per)
  let (valueQuantity, valueUnit) = Quantity.unitOfSchema(in_)
  if priceQuantity.name != valueQuantity.name {
    Error(
      `cannot charge ${valueQuantity.name} in ${valueUnit} at a price per ${priceUnit}, ` ++
      `which is a unit of ${priceQuantity.name}`,
    )
  } else {
    Quantity.convert(
      priceQuantity,
      quantity,
      ~from=valueUnit,
      ~to=priceUnit,
    )->Result.flatMap(converted => {
      let amount = roundHalfAway(snap(price.amount *. converted))
      Math.abs(amount) <= Money.maxSafeInteger
        ? Ok(Money.make(~amount, ~currency=price.currency))
        : Error(
            `cannot charge ${Float.toString(quantity)} ${valueUnit} at ${Money.format(
                price,
              )} per ${priceUnit}: ` ++ `the amount is past the largest one that stays exact`,
          )
    })
  }
}

/** A price per one unit as a price per another of the same quantity: 39 ct per
    kWh is 39,000 ct per MWh. The currency never changes. Refused where the
    result is not whole minor units (39 ct per MWh per kWh), since a price is
    money and is never rounded quietly. */
let convert = (price: t, ~from: S.t<Quantity.t>, ~to: S.t<Quantity.t>): result<t, string> => {
  let (fromQuantity, fromUnit) = Quantity.unitOfSchema(from)
  let (toQuantity, toUnit) = Quantity.unitOfSchema(to)
  if fromQuantity.name != toQuantity.name {
    Error(
      `cannot turn a price per ${fromUnit} into one per ${toUnit}: they measure different things`,
    )
  } else {
    // A price per unit goes the other way round from a value: per larger unit, more money.
    Quantity.convert(
      fromQuantity,
      price.amount,
      ~from=toUnit,
      ~to=fromUnit,
    )->Result.flatMap(raw => {
      let amount = snap(raw)
      Math.trunc(amount) == amount
        ? Ok(Money.make(~amount, ~currency=price.currency))
        : Error(
            `${Money.format(price)} per ${fromUnit} is ${Float.toString(
                amount,
              )} minor units per ${toUnit}, not a whole amount`,
          )
    })
  }
}
