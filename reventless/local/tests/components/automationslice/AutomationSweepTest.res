// The local platform sweeps pending automation items as AWS does: a deadline,
// counted from its event's recorded time, passes without another event, a failed command is retried up to maxRetries,
// and what the sweep moved is written back to the query store.

open JestGlobals
open AutomationSweepFixtures

module Callback = ReventlessCore.AutomationSlice_Callback

// Only Date is faked, so `process` sees the time a test sets while Effect's own
// scheduling still runs on real timers.
type jestObj
type fakeTimersConfig = {doNotFake: array<string>}
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: (jestObj, fakeTimersConfig) => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external setSystemTime: (jestObj, float) => unit = "setSystemTime"

let setNow = millis => jest->setSystemTime(millis)

let commandIds = () => publishedCommands.contents->Array.map(c => c.id)

describe("the local automation sweep", () => {
  let _ = beforeAll(() =>
    jest->useFakeTimers({
      doNotFake: [
        "hrtime",
        "nextTick",
        "performance",
        "queueMicrotask",
        "setImmediate",
        "clearImmediate",
        "setInterval",
        "clearInterval",
        "setTimeout",
        "clearTimeout",
      ],
    })
  )
  let _ = afterAll(() => jest->useRealTimers)

  let _ = beforeAllAsync(async () => {
    let _ = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await orderResource.name->TestRunner.resolve
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
  })

  let _ = beforeEach(() => {
    publishedCommands := []
    failPublish := false
    setNow(0.)
  })

  testPromise("sends a deadline's command once it is due, with no further event", async () => {
    await placeOrder("o1", ~within=100.)
    expect(commandIds())->toEqual([])

    await LocalAutomationSweep.sweepOnce()
    expect(commandIds())->toEqual([])

    setNow(100.)
    await LocalAutomationSweep.sweepOnce()
    expect(commandIds())->toEqual(["o1"])
  })

  testPromise("writes what it moved back to the query store", async () => {
    await placeOrder("o2", ~within=100.)
    expect(storedRow("o2")->Option.map(row => row.status))->toEqual(Some(Callback.Pending))

    setNow(100.)
    await LocalAutomationSweep.sweepOnce()
    expect(storedRow("o2")->Option.map(row => row.status))->toEqual(Some(Callback.Processing))
  })

  testPromise("retries a failed command up to maxRetries, then abandons it", async () => {
    setNow(100.)
    failPublish := true
    await placeOrder("o3", ~within=0.)
    expect(storedRow("o3")->Option.map(row => (row.status, row.retryCount)))->toEqual(
      Some((Callback.Failed, 1)),
    )

    await LocalAutomationSweep.sweepOnce()
    expect(storedRow("o3")->Option.map(row => (row.status, row.retryCount)))->toEqual(
      Some((Callback.Abandoned, 2)),
    )

    failPublish := false
    await LocalAutomationSweep.sweepOnce()
    expect(commandIds()->Array.includes("o3"))->toBe(false)
  })

  testSync("waits five minutes by default, as on AWS", () => {
    expect(LocalAutomationSweep.intervalSeconds())->toBe(300)
  })

  testSync("waits REVENTLESS_LOCAL_SWEEP_SECONDS when it is a positive number", () => {
    let key = "REVENTLESS_LOCAL_SWEEP_SECONDS"
    NodeProcess.env->Dict.set(key, "15")
    let shortened = LocalAutomationSweep.intervalSeconds()
    NodeProcess.env->Dict.set(key, "soon")
    let malformed = LocalAutomationSweep.intervalSeconds()
    NodeProcess.env->Dict.delete(key)
    expect((shortened, malformed))->toEqual((15, 300))
  })
})
