# @reventlessdev/reventless-standin

Stand-ins for the things and services at an app's edge: a charger that sends its meter readings,
a payment provider that confirms. In development none of them is there; a stand-in plays one.

A stand-in is a client of the platform's public doors only. It reads the app's views through
GraphQL, and sends what the real thing sends **through the door the real thing will use**: the
inbound translation's webhook, signed with the door's secret.

## Kinds and twins

A **kind** is defined once, for a thing or a service, with its state, its timers and the messages
it may send:

```rescript
let charger = Standin.Thing.make({
  name: "Charger",
  view: "Charging_Chargers",        // one twin per row
  idField: "chargerId",
  selection: "chargerId maxPowerKw",
  init: (~id, ~row, ~random) => {...},
  timers: [{name: "meter", everyMs: 60_000., run: (~id, state, ~elapsedMs, ~random, ~now) => {...}}],
  messages: [],                     // sent by hand, for one twin
  describe: state => ...,           // the state as a person reads it
})
```

A **thing** has one twin per row of the view that lists it; a row added later gets a twin at the
next read, one removed loses it. A **service** has one twin.

## Time

Timers run forward only. A **speed** (`Seed.Pace.parseSpeed`, `10x`) shortens every interval; a
step is told the simulated interval it covers, so a value that grows with time (energy from power)
is computed from it, while every time a send carries is the true one.

Every twin draws its random values from its own generator, seeded by the run's seed, the kind and
its id, so a run started with one seed sends the same values.

## Running

```rescript
let runtime = Standin.Runtime.make(~client, ~doors, ~commands, ~kinds=[charger], ~speed=10., ())
await runtime->Standin.Runtime.start
await runtime->Standin.Runtime.stop   // ends every timer, waits for the sends under way
```

`Standin.Doors.fromRegistryEntry` reads what a running local platform publishes: where to read
views and log in, and each door with its secret. `Seed.Commands.checkBody` checks every body
against the API's description before it is sent.

## License

Apache-2.0
