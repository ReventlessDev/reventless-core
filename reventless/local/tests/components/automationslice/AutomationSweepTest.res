// The local platform sweeps pending automation items as AWS does: a deadline
// passes without another event, a failed command is retried up to maxRetries,
// and what the sweep moved is written back to the query store.

open JestGlobals
open AutomationSweepFixtures

module Callback = ReventlessCore.AutomationSlice_Callback

let commandIds = () => publishedCommands.contents->Array.map(c => c.id)

describe("the local automation sweep", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await slice->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await orderResource.name->TestRunner.resolve
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
  })

  let _ = beforeEach(() => {
    publishedCommands := []
    failPublish := false
    clock := 0.
  })

  testPromise("sends a deadline's command once it is due, with no further event", async () => {
    await placeOrder("o1", ~dueAt=100.)
    expect(commandIds())->toEqual([])

    await LocalAutomationSweep.sweepOnce()
    expect(commandIds())->toEqual([])

    clock := 100.
    await LocalAutomationSweep.sweepOnce()
    expect(commandIds())->toEqual(["o1"])
  })

  testPromise("writes what it moved back to the query store", async () => {
    await placeOrder("o2", ~dueAt=100.)
    expect(storedRow("o2")->Option.map(row => row.status))->toEqual(Some(Callback.Pending))

    clock := 100.
    await LocalAutomationSweep.sweepOnce()
    expect(storedRow("o2")->Option.map(row => row.status))->toEqual(Some(Callback.Processing))
  })

  testPromise("retries a failed command up to maxRetries, then abandons it", async () => {
    clock := 100.
    failPublish := true
    await placeOrder("o3", ~dueAt=0.)
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
