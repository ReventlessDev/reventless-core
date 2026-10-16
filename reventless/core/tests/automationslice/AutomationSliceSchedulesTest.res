// A slice's schedule rows, and how the platform is brought in line with them: the
// declared time is written unless an event set or cleared the slice-wide key, the
// platform gets what it is missing and loses what the rows do not hold, and a
// once-only time already past is not put again.

open JestGlobals

module Schedules = AutomationSlice_Schedules

let at = iso => Date.fromString(iso)->Date.getTime
let daily6 = Reventless.Schedule.Calendar({calendar: Daily({hour: 6, minute: 0})})
let daily18 = Reventless.Schedule.Calendar({calendar: Daily({hour: 18, minute: 0})})
let now = at("2026-10-16T12:00:00Z")

// A platform that holds its schedules in a dict and records what it was told.
let fakePlatform = (~held: array<string>=[]) => {
  let schedules = Dict.fromArray(held->Array.map(name => (name, daily6)))
  let calls = []
  let platform: ReventlessInfra.AutomationSlice.platformSchedules = {
    put: async (~key, time) => {
      calls->Array.push(`put ${key}`)
      schedules->Dict.set(key, time)
    },
    removeName: async name => {
      calls->Array.push(`remove ${name}`)
      schedules->Dict.delete(name)
    },
    names: async () => schedules->Dict.keysToArray,
    nameOf: key => key,
  }
  (platform, schedules, calls)
}

let liveKeys = rows =>
  rows
  ->Dict.valuesToArray
  ->Array.filter(row => row.Schedules.time->Option.isSome)
  ->Array.map(row => row.key)
  ->Array.toSorted(String.compare)

let set = (rows, key, time, ~recordedAt=now) =>
  rows->Schedules.apply(Set({key, time}), ~setBy="event", ~recordedAt)
let clear = (rows, key) => rows->Schedules.apply(Clear({key: key}), ~setBy="event", ~recordedAt=now)

describe("the declared time", () => {
  testSync("is written when no event has touched the slice-wide key", () => {
    let rows = Dict.make()
    rows->Schedules.declare(Some(daily6), ~now)
    expect(rows->Dict.get("default")->Option.flatMap(Schedules.timeOf))->toEqual(Some(daily6))
  })

  testSync("does not replace a time an event set", () => {
    let rows = Dict.make()
    let _ = rows->set("default", daily18)
    rows->Schedules.declare(Some(daily6), ~now)
    expect(rows->Dict.get("default")->Option.flatMap(Schedules.timeOf))->toEqual(Some(daily18))
  })

  testSync("does not come back after an event cleared it", () => {
    let rows = Dict.make()
    rows->Schedules.declare(Some(daily6), ~now)
    let _ = rows->clear("default")
    rows->Schedules.declare(Some(daily6), ~now)
    expect(rows->liveKeys)->toEqual([])
  })

  testSync("follows a changed declaration, and goes with it", () => {
    let rows = Dict.make()
    rows->Schedules.declare(Some(daily6), ~now)
    rows->Schedules.declare(Some(daily18), ~now)
    let changed = rows->Dict.get("default")->Option.flatMap(Schedules.timeOf)
    rows->Schedules.declare(None, ~now)
    expect((changed, rows->liveKeys))->toEqual((Some(daily18), []))
  })
})

describe("a change an event makes", () => {
  testSync("counts an After from when the event was recorded", () => {
    let rows = Dict.make()
    let _ =
      rows->set("o1", Once({moment: After(Minutes(10))}), ~recordedAt=at("2026-10-16T09:00:00Z"))
    expect(rows->Dict.get("o1")->Option.flatMap(Schedules.timeOf))->toEqual(
      Some(
        Reventless.Schedule.Once({
          moment: At({year: 2026, month: 10, day: 16, hour: 9, minute: 10}),
        }),
      ),
    )
  })

  testSync("refuses a time that cannot fire, and changes nothing", () => {
    let rows = Dict.make()
    let refused = rows->set("r1", Calendar({calendar: Daily({hour: 25, minute: 0})}))
    expect((refused->Result.isError, rows->liveKeys))->toEqual((true, []))
  })

  testSync("removes a once-only schedule when it fires, not a recurring one", () => {
    let rows = Dict.make()
    let _ = rows->set("o1", Once({moment: After(Minutes(10))}))
    let _ = rows->set("r1", daily18)
    rows->Schedules.fired(~key="o1")
    rows->Schedules.fired(~key="r1")
    expect(rows->liveKeys)->toEqual(["r1"])
  })
})

describe("the reconcile", () => {
  testPromise(
    "puts what the platform is missing and removes what the rows do not hold",
    async () => {
      let rows = Dict.make()
      let _ = rows->set("r1", daily18)
      let _ = rows->set("r2", daily18)
      let (platform, held, _) = fakePlatform(~held=["r2", "stray"])
      await rows->Schedules.reconcile(platform, ~declaredTime=None, ~now)
      expect(held->Dict.keysToArray->Array.toSorted(String.compare))->toEqual(["r1", "r2"])
    },
  )

  testPromise("does not put again a schedule an event set and the platform holds", async () => {
    let rows = Dict.make()
    let _ = rows->set("r1", daily18)
    let (platform, _, calls) = fakePlatform(~held=["r1"])
    await rows->Schedules.reconcile(platform, ~declaredTime=None, ~now)
    expect(calls)->toEqual([])
  })

  testPromise("puts the declared time again, in case it changed", async () => {
    let rows = Dict.make()
    let (platform, _, calls) = fakePlatform(~held=["default"])
    await rows->Schedules.reconcile(platform, ~declaredTime=Some(daily6), ~now)
    expect(calls)->toEqual(["put default"])
  })

  testPromise("drops a once-only time already past, from the rows and the platform", async () => {
    let rows = Dict.make()
    let _ =
      rows->set("o1", Once({moment: After(Minutes(10))}), ~recordedAt=at("2026-10-16T09:00:00Z"))
    let (platform, held, _) = fakePlatform(~held=["o1"])
    await rows->Schedules.reconcile(platform, ~declaredTime=None, ~now)
    expect((rows->liveKeys, held->Dict.keysToArray))->toEqual(([], []))
  })
})
