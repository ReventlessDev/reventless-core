open JestGlobals
open ReventlessSeed

// The fixture app's local platform with its stand-ins handed over: it starts
// with its chargers metering, serves them, takes a by-hand send that the app
// refuses or accepts, carries a translation's tell to the twin, and starts
// quiet with REVENTLESS_STANDINS=off.

let port = 48500 + Math.Int.random(0, 300) * 10
let on = ref(None)
let off = ref(None)
let it = r => r.contents->Option.getOrThrow

let waitFor = FixturePlatform.waitFor

let instances = (state: JSON.t) =>
  switch state->Seed.Commands.get("kinds") {
  | Some(Array([kind])) => kind->Seed.Commands.items("instances")
  | _ => []
  }

let instance = (state, id) =>
  instances(state)->Array.find(i => i->Seed.Commands.str("id") == Some(id))

let stateOf = async (p: FixturePlatform.t) => {
  let (_, json) = await p->FixturePlatform.request(~path="/__inmemory/standins")
  json
}

let readings = (state, id) =>
  switch instance(state, id)->Option.flatMap(i => i->Seed.Commands.get("state")) {
  | Some(s) =>
    switch s->Seed.Commands.get("readings") {
    | Some(Number(n)) => n
    | _ => 0.
    }
  | None => 0.
  }

let powerW = (state, id) =>
  instance(state, id)
  ->Option.flatMap(i => i->Seed.Commands.get("state"))
  ->Option.flatMap(s => s->Seed.Commands.get("powerW"))

beforeAllAsyncWithTimeout(async () => {
  let (a, b) = (
    FixturePlatform.start(~port, ~vars=[("REVENTLESS_STANDINS_SPEED", "600x")]),
    FixturePlatform.start(~port=port + 5, ~vars=[("REVENTLESS_STANDINS", "off")]),
  )
  let (a, b) = (await a, await b)
  on := Some(a)
  off := Some(b)
}, 120_000)

afterAllAsyncWithTimeout(async () => {
  let _ = await Promise.all(
    [on, off]->Array.filterMap(r => r.contents)->Array.map(FixturePlatform.stop),
  )
}, 30_000)

describe("a local platform's stand-ins, in the fixture app:", () => {
  testPromiseWithTimeout(
    "chargers meter from the start, and the registry entry says where they are served",
    async () => {
      let p = it(on)
      let client = await FixturePlatform.admin(p)
      await client->FixturePlatform.registerCharger("bay-1", ~maxPowerKw=22.)
      await client->FixturePlatform.registerCharger("bay-2", ~maxPowerKw=11.)
      await waitFor(async () => {
        let state = await stateOf(p)
        readings(state, "bay-1") >= 3. && readings(state, "bay-2") >= 3.
      }, ~until=Date.now() +. 20_000., ~what="both chargers to meter")
      let entry = NodeFs.readFileSync(p.entry)->JSON.parseOrThrow
      expect(entry->Seed.Commands.str("standins"))->toEqual(
        Some(`${FixturePlatform.base(p)}/__inmemory/standins`),
      )
      let state = await stateOf(p)
      expect(
        state
        ->Seed.Commands.items("recent")
        ->Array.every(s =>
          switch s->Seed.Commands.get("status") {
          | Some(Number(n)) => n >= 200. && n < 300.
          | _ => false
          }
        ),
      )->toBe(true)
    },
    60_000,
  )

  testPromiseWithTimeout(
    "a send by hand is answered as the app decides",
    async () => {
      let p = it(on)
      let send = async message => {
        let (status, json) = await p->FixturePlatform.request(
          ~method="POST",
          ~path="/__inmemory/standins/send",
          ~body=`{"kind": "Charger", "id": "bay-1", "message": "${message}", "fields": {"energyWh": 2}}`,
        )
        expect(status)->toBe(200)
        switch json->Seed.Commands.items("sent") {
        | [s] =>
          switch s->Seed.Commands.get("status") {
          | Some(Number(n)) => n
          | _ => 0.
          }
        | _ => 0.
        }
      }
      expect(await send("fault"))->toBe(422.)
      expect(await send("reading"))->toBe(200.)
      let (status, _) = await p->FixturePlatform.request(
        ~method="POST",
        ~path="/__inmemory/standins/send",
        ~body=`{"kind": "Charger", "id": "bay-9", "message": "reading"}`,
      )
      expect(status)->toBe(400)
    },
    60_000,
  )

  testPromiseWithTimeout(
    "a translation's tell reaches the twin, which meters at the power it was told",
    async () => {
      let p = it(on)
      let client = await FixturePlatform.admin(p)
      let _ = await client->Seed.Client.send(
        Seed.mutation("Charging_LimitPower", [("chargerId", Id("bay-1")), ("powerKw", Float(7.))]),
      )
      await waitFor(
        async () => powerW(await stateOf(p), "bay-1") == Some(Number(7000.)),
        ~until=Date.now() +. 20_000.,
        ~what="bay-1 to be told 7 kW",
      )
    },
    60_000,
  )

  testPromiseWithTimeout(
    "a kind switched off sends nothing by itself",
    async () => {
      let p = it(on)
      let (status, _) = await p->FixturePlatform.request(
        ~method="POST",
        ~path="/__inmemory/standins/switch",
        ~body=`{"kind": "Charger", "on": false}`,
      )
      expect(status)->toBe(200)
      await Seed.Client.sleep(300)
      let before = readings(await stateOf(p), "bay-2")
      await Seed.Client.sleep(600)
      expect(readings(await stateOf(p), "bay-2"))->toBe(before)
      let _ = await p->FixturePlatform.request(
        ~method="POST",
        ~path="/__inmemory/standins/switch",
        ~body=`{"kind": "Charger", "on": true}`,
      )
    },
    60_000,
  )

  testPromiseWithTimeout(
    "with REVENTLESS_STANDINS=off the platform starts quiet, and a told thing is not reachable",
    async () => {
      let p = it(off)
      let (status, _) = await p->FixturePlatform.request(~path="/__inmemory/standins")
      expect(status)->toBe(404)
      expect(NodeFs.readFileSync(p.entry)->JSON.parseOrThrow->Seed.Commands.str("standins"))->toBe(
        None,
      )
      let client = await FixturePlatform.admin(p)
      await client->FixturePlatform.registerCharger("bay-1", ~maxPowerKw=22.)
      await Seed.Client.sleep(600)
      expect(await client->Seed.Client.countNodes(~field="Charging_Sessions"))->toBe(0)
    },
    60_000,
  )
})
