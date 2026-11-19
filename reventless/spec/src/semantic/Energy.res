/**
Energy, one of the quantities core ships: Wh, kWh, MWh and GWh.

Each unit is a schema a field is declared with; the value stays a number in that
unit. The names are words because a value's name cannot start with a capital
(`MWh`), and one spelling for all four reads better than three.

@example
```rescript
@schema type state = {
  sessionId: string,
  delivered: @s.matches(Reventless.Energy.kilowattHour) float,
}
```
*/
include Quantity.Make({
  let name = Quantity.energy.name
  let adds = Quantity.energy.adds
  let units = Quantity.energy.units
})

let wattHour = in_("Wh")
let kilowattHour = in_("kWh")
let megawattHour = in_("MWh")
let gigawattHour = in_("GWh")
