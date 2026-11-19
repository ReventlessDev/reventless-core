// Test fixture spec for collecting quantities onto the structure.
//
// Energy twice (command and event) and in two units, a price per kWh, and power
// inside a list of records, so the structure lists each quantity once, finds one
// nested in a list, and counts a price's quantity as one the plugin uses.

@@reventless.spec("RateSession")

type state = bool
let initialState = false

@schema
type consumedEvent = SessionStarted

let evolve = (_state, _event) => true

@schema
type reading = {at: string, power: @s.matches(Reventless.Power.kilowatt) float}

@schema
type command =
  | RateSession({
      sessionId: string,
      delivered: @s.matches(Reventless.Energy.kilowattHour) float,
      price: @s.matches(Reventless.PricePer.unit(Reventless.Energy.kilowattHour))
      Reventless.Money.t,
      readings: array<reading>,
    })

@schema
type error = SessionNotFound

@schema
type event =
  SessionRated({sessionId: string, delivered: @s.matches(Reventless.Energy.megawattHour) float})

let decide = (_state, _command): result<array<event>, error> => Ok([])
