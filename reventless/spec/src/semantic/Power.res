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

/** Energy over a duration, as the power that held constant delivers it: 11 kWh
    over half an hour (1800 seconds) is 22 kW on average. `from` is a unit of
    energy, `to` one of power; a unit of another quantity is refused, and so is a
    duration of zero or less, which has no average.

    @example
    ```rescript
    Power.average(11.0, ~from="kWh", ~over=1800, ~to="kW") // Ok(22.0)
    ```
*/
let average = (energy: Quantity.t, ~from: string, ~over: Duration.t, ~to: string): result<
  t,
  string,
> => Quantity.average(~total=Quantity.energy, ~rate=def, energy, ~from, ~over, ~to)
