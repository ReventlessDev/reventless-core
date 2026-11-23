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

describe("Energy is power held over time", () => {
  testSync("energy says it is power held over time, an hour to a watt-hour", () => {
    expect(Quantity.energy.overTime)->toEqual(Some({Quantity.quantity: "power", seconds: 3600.0}))
    expect(Energy.def)->toEqual(Quantity.energy)
    expect(Quantity.power.overTime)->toEqual(None)
  })

  testSync("the relation survives the structure's JSON, and power carries none", () => {
    let json = Quantity.energy->Util_Sury.toJson(Quantity.defSchema)
    expect(json->Util_Sury.fromJson(Quantity.defSchema))->toEqual(Quantity.energy)
    expect(
      switch Quantity.power->Util_Sury.toJson(Quantity.defSchema) {
      | JSON.Object(d) => d->Dict.keysToArray->Array.includes("overTime")
      | _ => true
      },
    )->toBe(false)
  })

  testSync("a plugin's own quantity is never another held over time", () =>
    expect(
      Quantity.declare({
        name: "volume",
        adds: true,
        units: [{code: "l", factor: 1.0, words: "litre", plural: "litres"}],
        overTime: {quantity: "flow", seconds: 1.0},
      })->isError,
    )->toBe(true)
  )

  testSync("power over time is not energy", () =>
    expect(Quantity.secondsOver(~total=Quantity.power, ~rate=Quantity.energy)->isError)->toBe(true)
  )
})

describe("Energy.ofPower", () => {
  testSync("22 kW for half an hour is 11 kWh", () =>
    expect(Energy.ofPower(22.0, ~from="kW", ~over=1800, ~to="kWh"))->toEqual(Ok(11.0))
  )

  testSync("in W, Wh, MW and MWh", () => {
    expect(Energy.ofPower(500.0, ~from="W", ~over=7200, ~to="Wh"))->toEqual(Ok(1000.0))
    expect(Energy.ofPower(500.0, ~from="W", ~over=7200, ~to="kWh"))->toEqual(Ok(1.0))
    expect(Energy.ofPower(2.0, ~from="MW", ~over=3600, ~to="MWh"))->toEqual(Ok(2.0))
    expect(Energy.ofPower(2.0, ~from="MW", ~over=900, ~to="kWh"))->toEqual(Ok(500.0))
  })

  testSync("power fed back gives energy fed back; over no time, none", () => {
    expect(Energy.ofPower(-4.0, ~from="kW", ~over=3600, ~to="kWh"))->toEqual(Ok(-4.0))
    expect(Energy.ofPower(22.0, ~from="kW", ~over=0, ~to="kWh"))->toEqual(Ok(0.0))
  })

  testSync("a negative duration and a unit of another quantity are refused", () => {
    expect(Energy.ofPower(22.0, ~from="kW", ~over=-1, ~to="kWh")->isError)->toBe(true)
    expect(Energy.ofPower(22.0, ~from="kWh", ~over=60, ~to="kWh")->isError)->toBe(true)
    expect(Energy.ofPower(22.0, ~from="kW", ~over=60, ~to="kW")->isError)->toBe(true)
  })
})

describe("Power.average", () => {
  testSync("11 kWh over half an hour is 22 kW", () =>
    expect(Power.average(11.0, ~from="kWh", ~over=1800, ~to="kW"))->toEqual(Ok(22.0))
  )

  testSync("in Wh, W, MWh and MW", () => {
    expect(Power.average(1000.0, ~from="Wh", ~over=7200, ~to="W"))->toEqual(Ok(500.0))
    expect(Power.average(1.0, ~from="kWh", ~over=7200, ~to="W"))->toEqual(Ok(500.0))
    expect(Power.average(2.0, ~from="MWh", ~over=3600, ~to="MW"))->toEqual(Ok(2.0))
    expect(Power.average(500.0, ~from="kWh", ~over=900, ~to="MW"))->toEqual(Ok(2.0))
  })

  testSync("undoes Energy.ofPower", () =>
    expect(
      Energy.ofPower(7.4, ~from="kW", ~over=5400, ~to="kWh")->Result.flatMap(
        e => Power.average(e, ~from="kWh", ~over=5400, ~to="kW"),
      ),
    )->toEqual(Ok(7.4))
  )

  testSync("a duration of zero or less has no average and is refused", () => {
    switch Power.average(11.0, ~from="kWh", ~over=0, ~to="kW") {
    | Error(reason) => expect(reason->String.includes("longer than zero"))->toBe(true)
    | Ok(_) => expect("accepted")->toBe("refused")
    }
    expect(Power.average(11.0, ~from="kWh", ~over=-1800, ~to="kW")->isError)->toBe(true)
  })

  testSync("a unit of another quantity is refused", () => {
    expect(Power.average(11.0, ~from="kW", ~over=1800, ~to="kW")->isError)->toBe(true)
    expect(Power.average(11.0, ~from="kWh", ~over=1800, ~to="kWh")->isError)->toBe(true)
  })
})

describe("Energy.between", () => {
  testSync("1228.3 kWh then 1240.7 kWh is 12.4 kWh, with no float noise", () =>
    expect(Energy.between(1228.3, 1240.7))->toEqual(Ok(12.4))
  )

  testSync("a register that did not move gives none", () =>
    expect(Energy.between(1240.7, 1240.7))->toEqual(Ok(0.0))
  )

  testSync("whole watt-hours stay whole", () =>
    expect(Energy.between(1228300.0, 1240700.0))->toEqual(Ok(12400.0))
  )

  testSync("a later reading lower than the earlier is refused, never negative energy", () =>
    switch Energy.between(1240.7, 1228.3) {
    | Error(reason) => expect(reason->String.includes("went back"))->toBe(true)
    | Ok(_) => expect("accepted")->toBe("refused")
    }
  )

  testSync("a reading that is not a finite number is refused", () =>
    expect(Energy.between(1228.3, Float.Constants.positiveInfinity)->isError)->toBe(true)
  )
})
