// Tests for EventLog.replayStream (Phase B of effect-stream-integration plan).
// These tests verify the streaming replay API and the (state, count) fold pattern
// used by Aggregate_Callback to replace the two-pass replay + Array.length approach.

open AsyncTest
open AsyncTest.Expect
open EventLogFixtures

describe("EventLog.replayStream (in-memory adapter)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => reset())

  describe("basic streaming", () => {
    testPromise("replayStream returns all appended events", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "stream-1", [makeEvent'("stream-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))])
      let _ = await ops.append(1, "stream-1", [makeEvent'("stream-1", ItemEventLogSpec.ItemDeleted({id: "stream-1"}))])
      let count = await ops.replayStream("stream-1")
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(count)->toBe(2)
    })

    testPromise("replayStream for unknown id returns empty stream", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let count = await ops.replayStream("no-such-id")
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(count)->toBe(0)
    })

    testPromise("replayStream emits events in append order", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "stream-2", [makeEvent'("stream-2", ItemEventLogSpec.ItemCreated({name: "First"}))])
      let _ = await ops.append(1, "stream-2", [makeEvent'("stream-2", ItemEventLogSpec.ItemDeleted({id: "stream-2"}))])
      let events = await ops.replayStream("stream-2")
        ->Stream.runCollect
        ->Effect.runPromise
      expect(events->Array.length)->toBe(2)
      // First emitted is the Created event
      let first = events->Array.getUnsafe(0)
      expect(first)->toEqual(ItemEventLogSpec.ItemCreated({name: "First"}))
    })

    testPromise("separate aggregate IDs have independent streams", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "agg-X", [makeEvent'("agg-X", ItemEventLogSpec.ItemCreated({name: "X"}))])
      let _ = await ops.append(0, "agg-Y", [makeEvent'("agg-Y", ItemEventLogSpec.ItemCreated({name: "Y1"})), makeEvent'("agg-Y", ItemEventLogSpec.ItemDeleted({id: "agg-Y"}))])
      let countX = await ops.replayStream("agg-X")
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      let countY = await ops.replayStream("agg-Y")
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(countX)->toBe(1)
      expect(countY)->toBe(2)
    })

    testPromise("take(2) on a 5-event log returns only 2 events", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "stream-3", [
        makeEvent'("stream-3", ItemEventLogSpec.ItemCreated({name: "e1"})),
        makeEvent'("stream-3", ItemEventLogSpec.ItemDeleted({id: "e2"})),
        makeEvent'("stream-3", ItemEventLogSpec.ItemCreated({name: "e3"})),
        makeEvent'("stream-3", ItemEventLogSpec.ItemDeleted({id: "e4"})),
        makeEvent'("stream-3", ItemEventLogSpec.ItemCreated({name: "e5"})),
      ])
      let first2 = await ops.replayStream("stream-3")
        ->Stream.take(2)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(first2->Array.length)->toBe(2)
    })
  })

  describe("tuple fold — (state, count) pattern used in Aggregate_Callback", () => {
    testPromise("runFold produces correct count for sequenceNr", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(0, "fold-1", [makeEvent'("fold-1", ItemEventLogSpec.ItemCreated({name: "e1"})), makeEvent'("fold-1", ItemEventLogSpec.ItemDeleted({id: "e2"}))])
      let _ = await ops.append(2, "fold-1", [makeEvent'("fold-1", ItemEventLogSpec.ItemCreated({name: "e3"}))])
      let (_state, count) = await ops.replayStream("fold-1")
        ->Stream.runFold((None, 0), ((st, n), _ev) => (st, n + 1))
        ->Effect.runPromise
      expect(count)->toBe(3)
    })

    testPromise("runFold on empty stream returns initial accumulator", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let (state, count) = await ops.replayStream("unknown-fold")
        ->Stream.runFold((None, 0), ((st, n), _ev) => (st, n + 1))
        ->Effect.runPromise
      expect(state)->toEqual(None)
      expect(count)->toBe(0)
    })
  })
})
