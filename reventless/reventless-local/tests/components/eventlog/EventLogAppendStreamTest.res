// Tests for EventLog.appendStream (Phase H of effect-stream-integration plan).
// Verifies that a Stream<Spec.event> can drive sequential appends, and that
// the replayStream → appendStream pipeline works without an intermediate mapping step.
// Each test uses a unique aggregate ID to avoid state sharing with other tests.

open JestGlobals
open EventLogFixtures

describe("EventLog.appendStream (in-memory adapter)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => reset())

  describe("basic append", () => {
    testPromise("appendStream writes all events to storage", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let stream = [
        ItemEventLogSpec.ItemCreated({name: "e1"}),
        ItemEventLogSpec.ItemCreated({name: "e2"}),
        ItemEventLogSpec.ItemCreated({name: "e3"}),
      ]->Stream.fromIterable
      let _ = await ops.appendStream(0, "as-basic-1", stream)->Effect.runPromise
      let replayed = await ops.replay("as-basic-1")
      expect(replayed->Array.length)->toBe(3)
    })

    testPromise("appendStream on empty stream writes nothing", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.appendStream(0, "as-empty-1", Stream.empty)->Effect.runPromise
      let replayed = await ops.replay("as-empty-1")
      expect(replayed->Array.length)->toBe(0)
    })

    testPromise("appendStream preserves event order", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let stream = [
        ItemEventLogSpec.ItemCreated({name: "first"}),
        ItemEventLogSpec.ItemDeleted({id: "second"}),
      ]->Stream.fromIterable
      let _ = await ops.appendStream(0, "as-order-1", stream)->Effect.runPromise
      let replayed = await ops.replayStream("as-order-1")->Stream.runCollect->Effect.runPromise
      let first = replayed->Array.getUnsafe(0)
      expect(first)->toEqual(ItemEventLogSpec.ItemCreated({name: "first"}))
    })

    testPromise("appendStream after array append continues from correct sequenceNr", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(
        0,
        "as-seq-1",
        [makeEvent'("as-seq-1", ItemEventLogSpec.ItemCreated({name: "initial"}))],
      )
      let stream = [ItemEventLogSpec.ItemCreated({name: "streamed"})]->Stream.fromIterable
      let _ = await ops.appendStream(1, "as-seq-1", stream)->Effect.runPromise
      let replayed = await ops.replay("as-seq-1")
      expect(replayed->Array.length)->toBe(2)
    })
  })

  describe("replayStream → appendStream pipeline", () => {
    testPromise("can copy events from one aggregate to another via streams", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(
        0,
        "as-src-1",
        [
          makeEvent'("as-src-1", ItemEventLogSpec.ItemCreated({name: "a"})),
          makeEvent'("as-src-1", ItemEventLogSpec.ItemDeleted({id: "b"})),
        ],
      )
      let sourceStream = ops.replayStream("as-src-1")
      let _ = await ops.appendStream(0, "as-dst-1", sourceStream)->Effect.runPromise
      let destEvents = await ops.replay("as-dst-1")
      expect(destEvents->Array.length)->toBe(2)
    })

    testPromise("copied events round-trip through decode correctly", async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append(
        0,
        "as-src-2",
        [makeEvent'("as-src-2", ItemEventLogSpec.ItemCreated({name: "copied"}))],
      )
      let sourceStream = ops.replayStream("as-src-2")
      let _ = await ops.appendStream(0, "as-dst-2", sourceStream)->Effect.runPromise
      let destEvents = await ops.replayStream("as-dst-2")->Stream.runCollect->Effect.runPromise
      let first = destEvents->Array.getUnsafe(0)
      expect(first)->toEqual(ItemEventLogSpec.ItemCreated({name: "copied"}))
    })
  })
})
