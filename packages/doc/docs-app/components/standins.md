---
title: Stand-ins
---

## In plain words

An app talks to things and services at its edge: a charger that sends its meter readings, a
payment provider that confirms. In development none of them is there, so nothing arrives by itself,
and nothing arrives the way it will in production.

A **stand-in** plays one of them. It sends what the real thing sends **through the door the real
thing will use** (an [inbound translation](inboundtranslationslice.md)'s webhook, signed with the
door's secret), and it answers what the app tells the real thing through an
[outbound translation](outboundtranslationslice.md). A stand-in for a *thing* has one **twin** per
row of the view that lists the things, each with its own state; a stand-in for a *service* has one.

Stand-ins run on a **local platform only**. A deployed platform has none: there, a thing the app
tells something is *not reachable*.

## A kind

A kind is written once, in the app, with the package `reventless-standin`:

```rescript
module Standin = ReventlessStandin.Standin

let charger = Standin.Thing.make({
  name: "Charger",
  view: "Charging_Chargers",          // one twin per row
  idField: "chargerId",
  selection: "chargerId maxPowerKw",   // what a twin is made from
  init: (~id, ~row, ~random) => {...},
  timers: [
    {
      name: "meter",
      everyMs: 60_000.,               // a simulated minute
      run: (~id, state, ~elapsedMs, ~random, ~now) => {
        state: nextState,
        sends: [{slice: "MeterCharger", body: reading}],
      },
    },
  ],
  messages: [],                        // what a person may send for one twin by hand
  told: [                              // what it understands when the app tells it something
    {message: "setPower", run: (~id, state, ~body, ~now) => Ok({state: ..., sends: []})},
  ],
  describe: state => ...,              // the state as a person reads it
})
```

- **A send** names the inbound translation and carries the body its door takes. Before it is
  posted, the body is checked against the API's own description, so a misspelled field is named
  rather than refused at the door.
- **A timer** is told the simulated interval it covers (`elapsedMs`), so a value that grows with
  time is computed from it. Every time a twin writes is the true one.
- **Random values** come from a generator per twin, seeded by the run's seed, the kind and the
  twin's id: a run started with one seed sends the same values.
- `Standin.Service.make` takes the same, without `view`, `idField` and `selection`.

## On a local platform

The app hands its kinds to the platform before its servers start:

```rescript
ReventlessLocal.LocalStandins.use({kinds: [charger], speed: 10.})
Platform.startServers()
```

Once the servers listen, the stand-ins read their views, make their twins and run their timers.
A thing added to its view gets a twin with the next event. They run in the platform's process for
convenience and still use only the public doors: views through GraphQL, as an identity of their
own, and sends through the webhook doors.

| Variable | What it does |
|---|---|
| `REVENTLESS_STANDINS=off` | Nothing starts; every thing told something is not reachable |
| `REVENTLESS_STANDINS_SPEED` | How fast simulated time runs, such as `10x` |
| `REVENTLESS_STANDINS_SEED` | The seed of the run's random values |

## Telling a thing something

An outbound translation tells a thing something through the platform's devices capability, by
kind, instance and message:

```rescript
switch await capabilities.devices.tell(~kind="Charger", ~instance=chargerId,
  ~message="setPower", ~body) {
| Accepted | Refused(_) => Ok(None)
| NotReachable(why) => Error(why)   // told again later
}
```

On a local platform the running stand-ins answer: the twin's `told` handler changes its state,
and it meters at the new power from then on. A twin that does not exist, or no stand-ins at all,
answers `NotReachable`, as a real thing that is offline. In a scenario the capabilities fake
records the call, and `thenSent` reads it. See [Platform Capabilities](../platform-capabilities.md).

## Behaving as things do

A stand-in kinder than the thing makes every run green. Each kind has four rates, on and low by
default, and changed while it runs:

- **silence**: a twin stops sending for a few ticks, and comes back half the time with the
  readings it kept. One can also be silenced on purpose, which its state says;
- **repeats**: a send goes out twice;
- **late**: a send is held and goes out after a newer one;
- **drift**: a twin's own clock is off by seconds, in the times it writes.

A twin draws them from a generator of its own, so turning them up leaves the values the kind
draws unchanged, and one seed repeats a run.

## Served

| Route | What it does |
|---|---|
| `GET /__inmemory/standins` | Every kind: its instances with their state, its rates, whether it runs; the last sends with the doors' answers |
| `POST /__inmemory/standins/send` | `kind`, `id`, `message`, `fields`: sends one message for one twin now, and says what the door answered |
| `POST /__inmemory/standins/switch` | `kind`, `on`: a kind switched off sends nothing by itself |
| `POST /__inmemory/standins/misbehave` | `kind` and any of `silence`, `repeats`, `late`, `drift`; with `silenceInstance` and `ticks`, silences that twin |

The domain MCP server has the same as the tools `local_standins`, `local_standin_send`,
`local_standin_switch` and `local_standin_misbehave`, and the running platform's registry entry
names the routes under `standins`.

## Outside a platform

`Standin.Runtime` runs kinds against any running platform: `Standin.Doors.fromRegistryEntry` reads
what a local platform publishes about itself (where to read views and log in, each door with its
secret), and the runtime is started and stopped by hand. A stop ends every timer and waits for the
sends already under way.

## Related Components

- [InboundTranslationSlice](inboundtranslationslice.md): the door a stand-in sends through
- [OutboundTranslationSlice](outboundtranslationslice.md): how the app tells a thing something
- [StateViewSlice](stateviewslice.md): the view that lists the things
