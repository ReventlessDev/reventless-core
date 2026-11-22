open JestGlobals

// Money per a quantity's unit, and charging a quantity at it with one rounding.

let cents = minorUnits => Money.ofMinorUnits(~minorUnits, ~currency=Currency.EUR)
let perKWh = Energy.kilowattHour
let perMWh = Energy.megawattHour

let throws = (f: unit => unit): bool =>
  try {
    f()
    false
  } catch {
  | _ => true
  }

let isError = r =>
  switch r {
  | Error(_) => true
  | Ok(_) => false
  }

describe("PricePer.charge", () => {
  testSync("12.4 kWh at 39 ct per kWh is 4.84 €", () =>
    expect(PricePer.charge(cents(39.0), ~per=perKWh, 12.4, ~in_=perKWh))->toEqual(Ok(cents(484.0)))
  )

  testSync("the same energy at the price per MWh gives the same amount", () =>
    expect(PricePer.charge(cents(39000.0), ~per=perMWh, 12.4, ~in_=perKWh))->toEqual(
      Ok(cents(484.0)),
    )
  )

  testSync("the energy in MWh at a price per kWh gives the same amount", () =>
    expect(PricePer.charge(cents(39.0), ~per=perKWh, 0.0124, ~in_=perMWh))->toEqual(
      Ok(cents(484.0)),
    )
  )

  testSync("a half cent rounds away from zero, both ways", () => {
    // 2.5 kWh at 39 ct is 97.5 ct.
    expect(PricePer.charge(cents(39.0), ~per=perKWh, 2.5, ~in_=perKWh))->toEqual(Ok(cents(98.0)))
    expect(PricePer.charge(cents(39.0), ~per=perKWh, -2.5, ~in_=perKWh))->toEqual(Ok(cents(-98.0)))
    // The same half cent reached through a conversion.
    expect(PricePer.charge(cents(39000.0), ~per=perMWh, 2.5, ~in_=perKWh))->toEqual(Ok(cents(98.0)))
  })

  testSync("a price per kW (power) charged with energy is refused", () =>
    expect(PricePer.charge(cents(39.0), ~per=Power.kilowatt, 12.4, ~in_=perKWh)->isError)->toBe(
      true,
    )
  )

  testSync("the currency is the price's", () =>
    expect(
      PricePer.charge(
        Money.ofMinorUnits(~minorUnits=39.0, ~currency=Currency.JPY),
        ~per=perKWh,
        2.0,
        ~in_=perKWh,
      ),
    )->toEqual(Ok(Money.ofMinorUnits(~minorUnits=78.0, ~currency=Currency.JPY)))
  )
})

describe("PricePer.convert", () => {
  testSync("39 ct per kWh is 39,000 ct per MWh, and back", () => {
    expect(PricePer.convert(cents(39.0), ~from=perKWh, ~to=perMWh))->toEqual(Ok(cents(39000.0)))
    expect(PricePer.convert(cents(39000.0), ~from=perMWh, ~to=perKWh))->toEqual(Ok(cents(39.0)))
  })

  testSync("a price that is not whole minor units in the other unit is refused", () =>
    expect(PricePer.convert(cents(39.0), ~from=perMWh, ~to=perKWh)->isError)->toBe(true)
  )

  testSync("a unit of another quantity is refused", () =>
    expect(PricePer.convert(cents(39.0), ~from=perKWh, ~to=Power.kilowatt)->isError)->toBe(true)
  )
})

describe("PricePer.unit", () => {
  let schema = PricePer.unit(perKWh)

  testSync("the value is money, said as people say it", () =>
    expect(
      JSON.parseOrThrow(`{"amount": 0.39, "currency": "EUR"}`)->S.parseOrThrow(~to=schema),
    )->toEqual(cents(39.0))
  )

  testSync("the field says per which unit", () => {
    expect(Semantic.get(schema))->toEqual(
      Some({
        Semantic.id: Semantic.Id.pricePerUnit,
        payload: PerUnit({quantity: "energy", unit: "kWh"}),
      }),
    )
    expect(Quantity.fieldUnit(schema->S.castToUnknown))->toEqual(Some((Quantity.energy, "kWh")))
  })

  testSync("a schema that is not a quantity's unit is refused", () =>
    expect(throws(() => PricePer.unit(S.float)->ignore))->toBe(true)
  )
})
