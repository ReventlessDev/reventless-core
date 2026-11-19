/**
Power, one of the quantities core ships: W, kW and MW.

@example
```rescript
@schema type state = {
  chargerId: string,
  maxPower: @s.matches(Reventless.Power.kilowatt) float,
}
```
*/
include Quantity.Make({
  let name = Quantity.power.name
  let adds = Quantity.power.adds
  let units = Quantity.power.units
})

let watt = in_("W")
let kilowatt = in_("kW")
let megawatt = in_("MW")
