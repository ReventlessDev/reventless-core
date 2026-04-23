// Tests for optimistic locking conflict detection in EventLog (in-memory).

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open EventLogFixtures

describe("EventLog — conflict detection (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => reset())

  testPromise("append with stale sequenceNr returns conflict error", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append(
      0,
      "conflict-1",
      [makeEvent'("conflict-1", ItemEventLogSpec.ItemCreated({name: "First"}))],
    )
    // Now storage has 1 event for "conflict-1"; passing sequenceNr=0 again should conflict
    let result = await ops.append(
      0,
      "conflict-1",
      [makeEvent'("conflict-1", ItemEventLogSpec.ItemCreated({name: "Duplicate"}))],
    )
    expect(Result.isError(result))->toBe(true)
  })

  testPromise("append with correct sequenceNr succeeds after prior append", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append(
      0,
      "conflict-2",
      [makeEvent'("conflict-2", ItemEventLogSpec.ItemCreated({name: "First"}))],
    )
    let result = await ops.append(
      1,
      "conflict-2",
      [makeEvent'("conflict-2", ItemEventLogSpec.ItemDeleted({id: "conflict-2"}))],
    )
    expect(Result.isOk(result))->toBe(true)
  })

  testPromise("conflict does not publish events to event topic", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append(
      0,
      "conflict-3",
      [makeEvent'("conflict-3", ItemEventLogSpec.ItemCreated({name: "First"}))],
    )
    reset() // Reset captured count after first append
    let _ = await ops.append(
      0,
      "conflict-3",
      [makeEvent'("conflict-3", ItemEventLogSpec.ItemCreated({name: "Duplicate"}))],
    )
    expect(capturedTopicEventCount.contents)->toBe(0)
  })

  testPromise("conflict does not store events", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append(
      0,
      "conflict-4",
      [makeEvent'("conflict-4", ItemEventLogSpec.ItemCreated({name: "First"}))],
    )
    let _ = await ops.append(
      0,
      "conflict-4",
      [makeEvent'("conflict-4", ItemEventLogSpec.ItemCreated({name: "Should not be stored"}))],
    )
    let replayed = await ops.replay("conflict-4")
    expect(replayed->Array.length)->toBe(1)
  })

  testPromise("batch append with correct sequenceNr stores all events", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let result = await ops.append(0, "conflict-5", [
      makeEvent'("conflict-5", ItemEventLogSpec.ItemCreated({name: "e1"})),
      makeEvent'("conflict-5", ItemEventLogSpec.ItemDeleted({id: "e2"})),
    ])
    expect(Result.isOk(result))->toBe(true)
    let replayed = await ops.replay("conflict-5")
    expect(replayed->Array.length)->toBe(2)
  })
})
