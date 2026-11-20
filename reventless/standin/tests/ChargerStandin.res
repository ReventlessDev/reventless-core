// A charger, as the fixture app's tests play it: one twin per row of
// `Charging_Chargers`, charging from the start, reporting the energy of each
// simulated minute through the `MeterCharger` door.

open ReventlessSeed

type state = {sessionId: string, powerW: float, seq: int}

let minute = 60_000.

let reading = (~id, s: state, ~energyWh, ~now: Date.t): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("readingId", JSON.Encode.string(`${s.sessionId}-${s.seq->Int.toString}`)),
      ("chargerId", JSON.Encode.string(id)),
      ("sessionId", JSON.Encode.string(s.sessionId)),
      ("energyWh", JSON.Encode.float(energyWh)),
      ("powerW", JSON.Encode.float(s.powerW)),
      ("at", JSON.Encode.string(now->Date.toISOString)),
    ]),
  )

let kind = Standin.Thing.make({
  name: "Charger",
  view: "Charging_Chargers",
  idField: "chargerId",
  selection: "chargerId name maxPowerKw",
  init: (~id, ~row, ~random) => {
    let maxW = switch row->Seed.Commands.get("maxPowerKw") {
    | Some(Number(kw)) => kw *. 1000.
    | _ => 11000.
    }
    {
      sessionId: `${id}-s1`,
      powerW: Math.round(3700. +. Seed.Random.float(random) *. (maxW -. 3700.)),
      seq: 0,
    }
  },
  timers: [
    {
      name: "meter",
      everyMs: minute,
      run: (~id, s, ~elapsedMs, ~random as _, ~now) => {
        let s = {...s, seq: s.seq + 1}
        let energyWh = s.powerW *. elapsedMs /. 3_600_000.
        {state: s, sends: [{slice: "MeterCharger", body: reading(~id, s, ~energyWh, ~now)}]}
      },
    },
  ],
  messages: [
    {
      name: "reading",
      build: (~id, s, ~fields, ~now) => {
        let s = {...s, seq: s.seq + 1}
        let energyWh = switch fields->Dict.get("energyWh") {
        | Some(Number(wh)) => wh
        | _ => 0.
        }
        Ok({state: s, sends: [{slice: "MeterCharger", body: reading(~id, s, ~energyWh, ~now)}]})
      },
    },
  ],
  describe: s =>
    JSON.Encode.object(
      Dict.fromArray([
        ("sessionId", JSON.Encode.string(s.sessionId)),
        ("powerW", JSON.Encode.float(s.powerW)),
        ("readings", JSON.Encode.int(s.seq)),
      ]),
    ),
})
