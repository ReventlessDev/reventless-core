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

/** A constant power held over a duration, as energy: 22 kW for half an hour
    (1800 seconds) is 11 kWh. `from` is a unit of power, `to` one of energy; a
    unit of another quantity, or a negative duration, is refused.

    @example
    ```rescript
    Energy.ofPower(22.0, ~from="kW", ~over=1800, ~to="kWh") // Ok(11.0)
    ```
*/
let ofPower = (power: Quantity.t, ~from: string, ~over: Duration.t, ~to: string): result<
  t,
  string,
> => Quantity.accumulate(~total=def, ~rate=Quantity.power, power, ~from, ~over, ~to)

// The decimals a reading is written with, for a difference no finer than its
// readings; none where the number is written with an exponent.
let decimalsOf = (x: float): option<int> => {
  let written = Float.toString(x)
  if written->String.includes("e") {
    None
  } else {
    switch written->String.indexOf(".") {
    | -1 => Some(0)
    | i => Some(written->String.length - i - 1)
    }
  }
}

/** The energy between two readings of a meter's register, which only counts
    up: 1228.3 kWh then 1240.7 kWh is 12.4 kWh, in the readings' unit. A later
    reading lower than the earlier is refused: a register that went back is a
    fault, never negative energy. The difference is kept to the readings'
    decimals, so a float's subtraction adds no digits a meter did not show. */
let between = (earlier: t, later: t): result<t, string> =>
  if !Float.isFinite(earlier) || !Float.isFinite(later) {
    Error(`a meter reading is a finite number`)
  } else if later < earlier {
    Error(
      `the later reading ${Float.toString(later)} is lower than the earlier ` ++
      `${Float.toString(earlier)}: a register that only counts up went back`,
    )
  } else {
    switch (decimalsOf(earlier), decimalsOf(later)) {
    | (Some(a), Some(b)) if Math.Int.max(a, b) <= 12 =>
      let scale = Math.pow(10.0, ~exp=Int.toFloat(Math.Int.max(a, b)))
      Ok(Math.round((later -. earlier) *. scale) /. scale)
    | _ => Ok(later -. earlier)
    }
  }
