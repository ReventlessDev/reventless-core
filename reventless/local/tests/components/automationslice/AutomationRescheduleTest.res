// Schedules set by events, on the local platform: a recipient's choice is stored and
// starts their timer, the timer's tick sends their digest, unsubscribing removes
// both, and a rebuild from the events reproduces the rows and removes a stray timer.

open JestGlobals
open AutomationRescheduleFixtures

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external setSystemTime: (jestObj, float) => unit = "setSystemTime"
@send
external advanceTimersByTimeAsync: (jestObj, float) => promise<unit> = "advanceTimersByTimeAsync"

let time = iso => Date.fromString(iso)->Date.getTime
let at18 = Reventless.Schedule.Calendar({calendar: Daily({hour: 18, minute: 0})})
let at19Berlin = Reventless.Schedule.Calendar({
  calendar: Daily({hour: 19, minute: 0}),
  zone: "Europe/Berlin",
})

let settle = async () =>
  for _ in 1 to 20 {
    await jest->advanceTimersByTimeAsync(0.)
  }

let sorted = keys => keys->Array.toSorted(String.compare)

describe("schedules set by events, locally", () => {
  let slice = ref(None)
  let ops = async () =>
    await slice.contents->Option.getOrThrow->ReventlessCore.Component.operations->TestRunner.resolve

  let _ = beforeAllAsync(async () => {
    jest->useFakeTimers
    jest->setSystemTime(time("2026-10-16T12:00:00Z"))
    slice := Some(makeSlice())
    let _ = await ops()
    await settle()
  })
  let _ = afterAll(() => {
    LocalAutomationSchedules.reset()
    jest->useRealTimers
  })

  testPromise("a choice is stored and starts the recipient's timer", async () => {
    await publish(DigestTimeChosen({recipientId: "r1", time: at18}), ~recipientId="r1")
    await publish(DigestTimeChosen({recipientId: "r2", time: at19Berlin}), ~recipientId="r2")
    await settle()
    expect((storedSchedules(), (await timers())->sorted))->toEqual((
      [("r1", at18), ("r2", at19Berlin)],
      ["r1", "r2"],
    ))
  })

  testPromise("each recipient's tick comes at their own time and sends their digest", async () => {
    // 18:00 UTC is r1's; 19:00 in Berlin is 17:00 UTC, r2's.
    await jest->advanceTimersByTimeAsync(5. *. 3_600_000. +. 1_000.)
    await settle()
    expect(publishedCommands.contents->Array.map(c => c.id))->toEqual(["r2"])
    await jest->advanceTimersByTimeAsync(3_600_000.)
    await settle()
    // Nothing answers r2's command here, so 18:00's pass, an hour on, sends it again.
    expect(publishedCommands.contents->Array.map(c => c.id))->toEqual(["r2", "r2", "r1"])
  })

  testPromise("unsubscribing removes the recipient's row and timer, and only theirs", async () => {
    await publish(Unsubscribed({recipientId: "r1"}), ~recipientId="r1")
    await settle()
    expect((storedSchedules(), await timers()))->toEqual(([("r2", at19Berlin)], ["r2"]))
  })

  testPromise("a later reconcile keeps the times events set", async () => {
    let ops = await ops()
    await ops.reconcileSchedules()
    expect((storedSchedules(), await timers()))->toEqual(([("r2", at19Berlin)], ["r2"]))
  })

  testPromise(
    "a rebuild reproduces the rows from the events and removes a stray timer",
    async () => {
      let platform = LocalAutomationSchedules.platformFor(~slice=DigestSpec.name)
      await platform.put(~key="stray", at18)
      let events =
        [
          eventJson(DigestTimeChosen({recipientId: "r1", time: at18}), ~recipientId="r1"),
          eventJson(DigestTimeChosen({recipientId: "r3", time: at19Berlin}), ~recipientId="r3"),
          eventJson(Unsubscribed({recipientId: "r1"}), ~recipientId="r1"),
        ]->Array.map(((_, json)) => json)
      let ops = await ops()
      await ops.rebuildSchedules(events)
      expect((storedSchedules(), (await timers())->sorted))->toEqual(([("r3", at19Berlin)], ["r3"]))
    },
  )
})
