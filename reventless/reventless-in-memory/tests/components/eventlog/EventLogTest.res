// Integration tests for EventLog_Builder with in-memory adapters.

open AsyncTest
open AsyncTest.Expect
open EventLogFixtures

describe("EventLog (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => reset())

  testPromise("append stores events and replay returns them", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let event = ItemEventLogSpec.ItemCreated({name: "Widget"})
    let event' = makeEvent'("item-1", event)
    let _ = await ops.append(0, "item-1", [event'])
    let replayed = await ops.replay("item-1")
    expect(replayed->Array.length)->toBe(1)
    let first = replayed->Array.getUnsafe(0)
    expect(first)->toEqual(event)
  })

  testPromise("append publishes event to event topic", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let event' = makeEvent'("pub-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
    let _ = await ops.append(0, "pub-1", [event'])
    expect(capturedTopicEventCount.contents)->toBe(1)
  })

  testPromise("replay returns empty array for unknown id", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let events = await ops.replay("unknown-id")
    expect(events->Array.length)->toBe(0)
  })

  testPromise("multiple appends accumulate events", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append(0, "agg-1", [makeEvent'("agg-1", ItemEventLogSpec.ItemCreated({name: "First"}))])
    let _ = await ops.append(1, "agg-1", [makeEvent'("agg-1", ItemEventLogSpec.ItemDeleted({id: "agg-1"}))])
    let replayed = await ops.replay("agg-1")
    expect(replayed->Array.length)->toBe(2)
  })

  testPromise("separate aggregates have independent event logs", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append(0, "agg-A", [makeEvent'("agg-A", ItemEventLogSpec.ItemCreated({name: "A"}))])
    let _ = await ops.append(0, "agg-B", [makeEvent'("agg-B", ItemEventLogSpec.ItemDeleted({id: "B"}))])
    let eventsA = await ops.replay("agg-A")
    let eventsB = await ops.replay("agg-B")
    expect((eventsA->Array.length, eventsB->Array.length))->toEqual((1, 1))
  })
})
