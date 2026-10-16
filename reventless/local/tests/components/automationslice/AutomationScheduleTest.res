// A declared schedule on the local platform: it ticks the slice at its time, a tick
// delivered twice sends one command, a command left unanswered is sent again after
// the timeout, and a slice that maps the Clock without a schedule is refused.

open JestGlobals
open AutomationScheduleFixtures

module Callback = ReventlessCore.AutomationSlice_Callback

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external setSystemTime: (jestObj, float) => unit = "setSystemTime"
@send
external advanceTimersByTimeAsync: (jestObj, float) => promise<unit> = "advanceTimersByTimeAsync"

let time = iso => Date.fromString(iso)->Date.getTime
let morning = time("2026-10-16T06:00:00Z")
let dayItem = "default@2026-10-16T06:00Z"

let commandIds = () => publishedCommands.contents->Array.map(c => c.id)

// Lets the tick's detached work and Effect's own scheduling run to the end.
let settle = async () =>
  for _ in 1 to 20 {
    await jest->advanceTimersByTimeAsync(0.)
  }

describe("a declared schedule, locally", () => {
  let slice = ref(None)
  let ops = async () =>
    await slice.contents->Option.getOrThrow->ReventlessCore.Component.operations->TestRunner.resolve

  let _ = beforeAllAsync(async () => {
    jest->useFakeTimers
    jest->setSystemTime(time("2026-10-16T05:59:00Z"))
    slice := Some(makeSlice())
    let _ = await ops()
    await settle()
  })
  let _ = afterAll(() => {
    LocalAutomationSchedules.reset()
    jest->useRealTimers
  })

  testPromise("ticks the slice at its time, and process requests the report", async () => {
    await jest->advanceTimersByTimeAsync(59_000.)
    await settle()
    expect(commandIds())->toEqual([])

    await jest->advanceTimersByTimeAsync(1_000.)
    await settle()
    expect(commandIds())->toEqual([dayItem])
    expect(storedRow(dayItem)->Option.map(row => row.status))->toEqual(Some(Callback.Processing))
  })

  testPromise("the same tick delivered twice sends one command", async () => {
    let ops = await ops()
    await ops.tick(~key=Reventless.Clock.defaultKey, ~at=morning)
    await settle()
    expect(commandIds())->toEqual([dayItem])
  })

  testPromise("a command left unanswered is sent again after the timeout", async () => {
    await LocalAutomationSweep.sweepOnce()
    expect(commandIds())->toEqual([dayItem])

    jest->setSystemTime(Date.now() +. 15. *. 60_000.)
    await LocalAutomationSweep.sweepOnce()
    expect(commandIds())->toEqual([dayItem, dayItem])
    expect(storedRow(dayItem)->Option.map(row => (row.status, row.retryCount)))->toEqual(
      Some((Callback.Processing, 1)),
    )
  })

  testSync("a slice that maps the Clock without a schedule is refused", () => {
    let refusal = switch makeUnscheduled() {
    | _ => None
    | exception JsExn(err) => err->JsExn.message
    }
    expect(
      refusal->Option.map(
        m => m->String.includes("maps the Clock source but declares no schedule"),
      ),
    )->toEqual(Some(true))
  })
})
