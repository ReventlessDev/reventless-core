open JestGlobals
open ReventlessSeed

// The runtime against the fixture app, started as a child process: chargers
// meter through the signed door at a speed, a charger added to the view starts
// metering without a restart, and a reading can be sent by hand. Everything the
// stand-ins need is read from the platform's registry entry.

let port = 48000 + Math.Int.random(0, 300) * 10
let platform = ref(None)
let client = ref(None)
let doors = ref([])
// Every runtime a test starts, stopped at the end even when its test failed.
let started: array<Standin.Runtime.t> = []

let waitFor = FixturePlatform.waitFor
let theClient = () => client.contents->Option.getOrThrow
let register = (id, ~maxPowerKw) => FixturePlatform.registerCharger(theClient(), id, ~maxPowerKw)

let sessions = async () =>
  (
    await theClient()->Seed.Client.queryAllNodes(
      ~field="Charging_Sessions",
      ~selection="sessionId chargerId energyWh readings powerW",
    )
  )->Array.map(row => {
    let num = key =>
      switch row->Seed.Commands.get(key) {
      | Some(Number(n)) => n
      | _ => 0.
      }
    (
      row->Seed.Commands.str("chargerId")->Option.getOr(""),
      num("readings"),
      num("energyWh"),
      num("powerW"),
    )
  })

// The platform's own stand-ins are off: the runtime under test plays the chargers.
beforeAllAsyncWithTimeout(async () => {
  let p = await FixturePlatform.start(~port, ~vars=[("REVENTLESS_STANDINS", "off")])
  platform := Some(p)
  let entry = switch Standin.Doors.fromRegistryEntry(~path=p.entry) {
  | Ok(entry) => entry
  | Error(why) => failwith(why)
  }
  doors := entry.doors
  client := Some(await FixturePlatform.admin(p))
}, 120_000)

afterAllAsyncWithTimeout(async () => {
  let _ = await Promise.all(started->Array.map(Standin.Runtime.stop))
  switch platform.contents {
  | Some(p) => await FixturePlatform.stop(p)
  | None => ()
  }
}, 30_000)

describe("Standin.Runtime, against the fixture app:", () => {
  testPromiseWithTimeout(
    "chargers meter through the signed door, and one added to the view starts without a restart",
    async () => {
      await register("bay-1", ~maxPowerKw=22.)
      await register("bay-2", ~maxPowerKw=11.)
      let charger = ChargerStandin.make()
      charger.setRates(Standin.Kind.exact)
      let commands = await Seed.Commands.fetch(theClient())
      let sent = []
      // A simulated minute every 100 ms.
      let runtime = Standin.Runtime.make(
        ~client=theClient(),
        ~doors=doors.contents,
        ~commands,
        ~kinds=[charger],
        ~speed=600.,
        ~seed=42,
        ~refreshMs=200,
        ~onSent=s => sent->Array.push(s),
        (),
      )
      expect(runtime->Standin.Runtime.check(~slices=["MeterCharger"]))->toEqual(Ok())
      await waitFor(
        async () => (await theClient()->Seed.Client.countNodes(~field="Charging_Chargers")) == 2,
        ~until=Date.now() +. 10_000.,
        ~what="two chargers in the view",
      )
      started->Array.push(runtime)
      await runtime->Standin.Runtime.start
      await Seed.Client.sleep(600)
      await register("bay-3", ~maxPowerKw=7.4)
      await waitFor(
        async () => (await sessions())->Array.some(((id, _, _, _)) => id == "bay-3"),
        ~until=Date.now() +. 10_000.,
        ~what="bay-3 to meter",
      )
      // What comes back is this send's own post, however many the timers made meanwhile:
      // the kept list is full here, so each new post pushes out the oldest.
      let filler: Standin.Runtime.sent = {
        kind: "Charger",
        id: "earlier",
        slice: "",
        body: JSON.Encode.null,
        status: 200,
        at: "",
      }
      runtime.recent = Array.make(~length=Standin.Runtime.keep, filler)
      expect(
        (
          await runtime->Standin.Runtime.byHand(
            ~kind="Charger",
            ~id="bay-1",
            ~message="reading",
            ~fields=Dict.fromArray([("energyWh", JSON.Encode.float(1.))]),
          )
        )->Result.map(answers =>
          answers->Array.map(s => (s.kind, s.id, s.status >= 200 && s.status < 300))
        ),
      )->toEqual(Ok([("Charger", "bay-1", true)]))
      await runtime->Standin.Runtime.stop

      expect(sent->Array.length > 3)->toBe(true)
      expect(sent->Array.every(s => s.status >= 200 && s.status < 300))->toBe(true)
      let total = sent->Array.length->Int.toFloat
      await waitFor(
        async () =>
          (await sessions())->Array.reduce(0., (acc, (_, readings, _, _)) => acc +. readings) ==
            total,
        ~until=Date.now() +. 10_000.,
        ~what="every reading in the view",
      )
      let rows = await sessions()
      expect(rows->Array.map(((id, _, _, _)) => id)->Array.toSorted(String.compare))->toEqual([
        "bay-1",
        "bay-2",
        "bay-3",
      ])
      // A minute's energy at the twin's power, for every timed reading. Bay 1 and bay 2 were
      // there at the start, and each read its meter then, with no time elapsed: no energy.
      rows->Array.forEach(((id, readings, energyWh, powerW)) => {
        let atStart = id == "bay-1" || id == "bay-2" ? 1. : 0.
        let timed = (id == "bay-1" ? readings -. 1. : readings) -. atStart
        let expected = timed *. powerW /. 60. +. (id == "bay-1" ? 1. : 0.)
        expect(Math.abs(energyWh -. expected) < 0.01)->toBe(true)
      })
    },
    60_000,
  )

  // At real speed a minute is a minute: each of the three chargers reads its meter as the runtime starts, as a
  // device reports when it starts, and not first a minute later.
  testPromiseWithTimeout(
    "every timer runs once as the runtime starts, with no time elapsed",
    async () => {
      let charger = ChargerStandin.make()
      charger.setRates(Standin.Kind.exact)
      let commands = await Seed.Commands.fetch(theClient())
      let sent = []
      let runtime = Standin.Runtime.make(
        ~client=theClient(),
        ~doors=doors.contents,
        ~commands,
        ~kinds=[charger],
        ~speed=1.,
        ~seed=44,
        ~refreshMs=60_000,
        ~onSent=s => sent->Array.push(s),
        (),
      )
      started->Array.push(runtime)
      await runtime->Standin.Runtime.start
      await waitFor(
        async () => sent->Array.length >= 3,
        ~until=Date.now() +. 10_000.,
        ~what="a reading from each charger at the start",
      )
      await runtime->Standin.Runtime.stop
      expect((
        sent->Array.map(s => s.id)->Array.toSorted(String.compare),
        sent->Array.every(s =>
          switch s.body->Seed.Commands.get("energyWh") {
          | Some(Number(wh)) => wh == 0.
          | _ => false
          }
        ),
      ))->toEqual((["bay-1", "bay-2", "bay-3"], true))
    },
    30_000,
  )

  testPromiseWithTimeout(
    "a twin told a new power meters at it, and says no to what it does not understand",
    async () => {
      let charger = ChargerStandin.make()
      charger.setRates(Standin.Kind.exact)
      let commands = await Seed.Commands.fetch(theClient())
      let runtime = Standin.Runtime.make(
        ~client=theClient(),
        ~doors=doors.contents,
        ~commands,
        ~kinds=[charger],
        ~speed=600.,
        ~seed=43,
        ~refreshMs=200,
        (),
      )
      started->Array.push(runtime)
      await runtime->Standin.Runtime.start
      let tell = (instance, message, body) =>
        runtime->Standin.Runtime.tell(
          ~kind="Charger",
          ~instance,
          ~message,
          ~body=JSON.parseOrThrow(body),
        )
      expect(await tell("bay-1", "setPower", `{"powerKw": 11}`))->toEqual(Standin.Accepted)
      expect(await tell("bay-1", "setPower", `{"powerKw": -1}`))->toEqual(
        Standin.Refused("powerKw must be a positive number"),
      )
      expect(await tell("bay-1", "unlock", `{}`))->toEqual(
        Standin.Refused("Charger does not understand unlock"),
      )
      expect(await tell("bay-9", "setPower", `{"powerKw": 11}`))->toEqual(
        Standin.NotReachable("Charger bay-9 is not played by any stand-in"),
      )
      let session = switch runtime->Standin.Runtime.state {
      | [(_, twins)] =>
        twins
        ->Array.find(((id, _)) => id == "bay-1")
        ->Option.flatMap(((_, t)) => t->Seed.Commands.get("state"))
        ->Option.flatMap(s => s->Seed.Commands.str("sessionId"))
        ->Option.getOrThrow
      | _ => failwith("one kind")
      }
      await waitFor(
        async () =>
          (
            await theClient()->Seed.Client.queryAllNodes(
              ~field="Charging_Sessions",
              ~selection="sessionId powerW",
            )
          )->Array.some(
            row =>
              row->Seed.Commands.str("sessionId") == Some(session) &&
                row->Seed.Commands.get("powerW") == Some(Number(11000.)),
          ),
        ~until=Date.now() +. 10_000.,
        ~what="bay-1 to meter at 11 kW",
      )
      await runtime->Standin.Runtime.stop
    },
    60_000,
  )

  testPromiseWithTimeout(
    "with repeats turned up, readings are sent twice now and then and counted once",
    async () => {
      let charger = ChargerStandin.make()
      charger.setRates({...Standin.Kind.exact, repeats: 0.5})
      let commands = await Seed.Commands.fetch(theClient())
      let sent = []
      let runtime = Standin.Runtime.make(
        ~client=theClient(),
        ~doors=doors.contents,
        ~commands,
        ~kinds=[charger],
        ~speed=600.,
        ~seed=44,
        ~refreshMs=200,
        ~onSent=s => sent->Array.push(s),
        (),
      )
      started->Array.push(runtime)
      await runtime->Standin.Runtime.start
      await Seed.Client.sleep(800)
      await runtime->Standin.Runtime.stop
      let readingOf = (s: Standin.Runtime.sent) =>
        s.body->Seed.Commands.str("readingId")->Option.getOr("")
      let distinct = sent->Array.map(readingOf)->Set.fromArray->Set.size
      expect(sent->Array.length > distinct)->toBe(true)
      expect(sent->Array.every(s => s.status >= 200 && s.status < 300))->toBe(true)
      let sessions = sent->Array.map(s => s.body->Seed.Commands.str("sessionId")->Option.getOr(""))
      let counted = async () =>
        (
          await theClient()->Seed.Client.queryAllNodes(
            ~field="Charging_Sessions",
            ~selection="sessionId readings",
          )
        )
        ->Array.filter(row =>
          sessions->Array.includes(row->Seed.Commands.str("sessionId")->Option.getOr(""))
        )
        ->Array.reduce(0., (acc, row) =>
          switch row->Seed.Commands.get("readings") {
          | Some(Number(n)) => acc +. n
          | _ => acc
          }
        )
      await waitFor(
        async () => (await counted()) == distinct->Int.toFloat,
        ~until=Date.now() +. 10_000.,
        ~what="each reading counted once",
      )
    },
    60_000,
  )
})
