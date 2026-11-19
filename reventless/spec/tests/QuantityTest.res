open JestGlobals

// A number in a declared quantity and unit: the standard set, converting between
// units, and a quantity a plugin declares.

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

describe("Quantity.convert", () => {
  testSync("1240 kWh is 1.24 MWh, and back", () => {
    expect(Energy.convert(1240.0, ~from="kWh", ~to="MWh"))->toEqual(Ok(1.24))
    expect(Energy.convert(1.24, ~from="MWh", ~to="kWh"))->toEqual(Ok(1240.0))
  })

  testSync(
    "every standard unit converts to the first and back without loss for whole numbers",
    () => {
      let lossy = Quantity.standard->Array.flatMap(
        q =>
          q.units->Array.filterMap(
            u => {
              let first = (q.units->Array.getUnsafe(0)).code
              let there = Quantity.convert(q, 7.0, ~from=u.code, ~to=first)
              let back = there->Result.flatMap(v => Quantity.convert(q, v, ~from=first, ~to=u.code))
              back == Ok(7.0) ? None : Some(`${q.name} ${u.code}`)
            },
          ),
      )
      expect(lossy)->toEqual([])
    },
  )

  testSync("a unit of another quantity is refused", () =>
    expect(Energy.convert(1.0, ~from="kWh", ~to="kW")->isError)->toBe(true)
  )
})

describe("Quantity schema", () => {
  testSync("a value stays a plain number", () =>
    expect(JSON.Encode.float(12.4)->S.parseOrThrow(~to=Energy.kilowattHour))->toBe(12.4)
  )

  testSync("a negative value is a value: energy fed back", () =>
    expect(JSON.Encode.float(-3.0)->S.parseOrThrow(~to=Energy.kilowattHour))->toBe(-3.0)
  )

  testSync("the field names its quantity and unit", () => {
    expect(Semantic.get(Energy.kilowattHour))->toEqual(
      Some({Semantic.id: Semantic.Id.quantity, payload: InUnit({quantity: "energy", unit: "kWh"})}),
    )
    expect(Quantity.fieldUnit(Power.kilowatt->S.castToUnknown))->toEqual(
      Some((Quantity.power, "kW")),
    )
  })

  testSync("the unit is read through an optional field and a list", () => {
    expect(Quantity.fieldUnit(S.option(Energy.megawattHour)->S.castToUnknown))->toEqual(
      Some((Quantity.energy, "MWh")),
    )
    expect(Quantity.fieldUnit(S.array(Energy.wattHour)->S.castToUnknown))->toEqual(
      Some((Quantity.energy, "Wh")),
    )
  })

  testSync("a code the quantity does not have is refused at the declaration", () =>
    expect(throws(() => Energy.in_("kW")->ignore))->toBe(true)
  )
})

module Volume = Quantity.Make({
  let name = "volume"
  let adds = true
  let units = [
    {Quantity.code: "l", factor: 1.0, words: "litre", plural: "litres"},
    {code: "m3", factor: 1000.0, words: "cubic metre", plural: "cubic metres"},
  ]
})

describe("A quantity a plugin declares", () => {
  testSync("is built and converts like a standard one", () => {
    expect(Volume.convert(2.5, ~from="m3", ~to="l"))->toEqual(Ok(2500.0))
    expect(Quantity.fieldUnit(Volume.in_("l")->S.castToUnknown))->toEqual(Some((Volume.def, "l")))
  })

  testSync("a standard quantity's name is refused, with the reason", () =>
    switch Quantity.declare({
      name: "energy",
      adds: true,
      units: [{code: "J", factor: 1.0, words: "joule", plural: "joules"}],
    }) {
    | Error(reason) => expect(reason->String.includes("never redefines"))->toBe(true)
    | Ok(_) => expect("accepted")->toBe("refused")
    }
  )

  testSync("a standard quantity unchanged is accepted", () =>
    expect(Quantity.declare(Quantity.energy))->toEqual(Ok(Quantity.energy))
  )

  testSync("the first unit counts the factors, so its factor is 1", () =>
    expect(
      Quantity.declare({
        name: "volume",
        adds: true,
        units: [{code: "m3", factor: 1000.0, words: "cubic metre", plural: "cubic metres"}],
      })->isError,
    )->toBe(true)
  )

  testSync("a factor of zero, no unit and a code twice are refused", () => {
    let u = (code, factor) => {Quantity.code, factor, words: code, plural: code}
    expect(
      Quantity.declare({name: "v", adds: true, units: [u("a", 1.0), u("b", 0.0)]})->isError,
    )->toBe(true)
    expect(Quantity.declare({name: "v", adds: true, units: []})->isError)->toBe(true)
    expect(
      Quantity.declare({name: "v", adds: true, units: [u("a", 1.0), u("a", 2.0)]})->isError,
    )->toBe(true)
  })

  testSync("two declarations of one name that differ are a conflict", () => {
    let other = {...Volume.def, units: [{code: "l", factor: 1.0, words: "liter", plural: "liters"}]}
    expect(Quantity.conflicts([Volume.def, Volume.def, Quantity.energy]))->toEqual([])
    expect(Quantity.conflicts([Volume.def, other])->Array.length)->toBe(1)
  })
})
