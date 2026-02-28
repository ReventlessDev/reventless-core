// Tests for DcbEventLog.readStream (Phase D of effect-stream-integration plan).
// Mirrors the pattern of EventLogStreamTest.res for the DCB event log.

open AsyncTest
open AsyncTest.Expect
open DcbFixtures

let tagQuery = (id: string): Reventless.DcbTag.query => [
  {tags: [{Reventless.DcbTag.key: "id", value: id}]},
]

let typeQuery = (eventType: string): Reventless.DcbTag.query => [
  {eventTypes: [eventType]},
]

let addItemJson = (id, name) =>
  DcbFixtures.AddItemSpec.AddItem({id, name})->S.reverseConvertToJsonOrThrow(
    DcbFixtures.AddItemSpec.commandSchema,
  )

describe("DcbEventLog.readStream (in-memory adapter)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  describe("basic streaming", () => {
    testPromise("readStream for tag with no matching events returns empty stream", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let count = await ops.readStream(~query=tagQuery("no-such-id"))
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(count)->toBe(0)
    })

    testPromise("readStream emits all events matching a tag query", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await dispatch(addItemJson("stream-1", "Widget"), "stream-1")
      let count = await ops.readStream(~query=tagQuery("stream-1"))
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(count)->toBe(1)
    })

    testPromise("readStream for distinct IDs returns independent streams", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await dispatch(addItemJson("stream-A", "Alpha"), "stream-A")
      let _ = await dispatch(addItemJson("stream-B", "Beta"), "stream-B")
      let countA = await ops.readStream(~query=tagQuery("stream-A"))
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      let countB = await ops.readStream(~query=tagQuery("stream-B"))
        ->Stream.runFold(0, (n, _) => n + 1)
        ->Effect.runPromise
      expect(countA)->toBe(1)
      expect(countB)->toBe(1)
    })

    testPromise("take(1) limits stream without loading all", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await dispatch(addItemJson("stream-C1", "C1"), "stream-C1")
      let _ = await dispatch(addItemJson("stream-C2", "C2"), "stream-C2")
      // Broad query: all ItemAdded events regardless of tag value
      let result = await ops.readStream(~query=typeQuery("ItemAdded"))
        ->Stream.take(1)
        ->Stream.runCollect
        ->Effect.runPromise
      expect(result->Array.length)->toBe(1)
    })
  })

  describe("fold patterns — (decisionModel, headPosition) used in StateChangeSlice_Callback", () => {
    testPromise("runFold extracts last headPosition for append condition", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await dispatch(addItemJson("fold-1", "FoldItem"), "fold-1")
      let (_, headPosition) = await ops.readStream(~query=tagQuery("fold-1"))
        ->Stream.runFold(((), None), ((_dm, _pos), se) => ((), Some(se.position)))
        ->Effect.runPromise
      expect(Option.isSome(headPosition))->toBe(true)
    })

    testPromise("runFold on empty stream returns initial accumulator", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let (_, headPosition) = await ops.readStream(~query=tagQuery("no-such-id-fold"))
        ->Stream.runFold((false, None), ((_dm, _pos), se) => (true, Some(se.position)))
        ->Effect.runPromise
      expect(headPosition)->toEqual(None)
    })
  })

  describe("StateChangeSlice regression — second command sees first event via stream fold", () => {
    testPromise("second AddItem with same ID is rejected (decision model sees existing event)", async () => {
      // First command succeeds → ItemAdded event stored
      // Second command: readStream folds all events → decisionModel = true (exists)
      // decide(true, AddItem) → Error(ItemAlreadyExists) → no new events
      let id = "dup-test-stream"
      let _ = await dispatch(addItemJson(id, "First"), id)
      let countBefore = capturedEventCount.contents
      let _ = await dispatch(addItemJson(id, "Duplicate"), id)
      // Duplicate command must not publish a second event
      expect(capturedEventCount.contents)->toBe(countBefore)
    })

    testPromise("second AddItem with different ID succeeds", async () => {
      let id1 = "distinct-1"
      let id2 = "distinct-2"
      let _ = await dispatch(addItemJson(id1, "First"), id1)
      let countAfterFirst = capturedEventCount.contents
      let _ = await dispatch(addItemJson(id2, "Second"), id2)
      // New ID should publish an event
      expect(capturedEventCount.contents)->toBe(countAfterFirst + 1)
    })
  })
})
