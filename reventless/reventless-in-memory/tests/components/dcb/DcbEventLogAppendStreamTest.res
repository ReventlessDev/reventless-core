// Tests for DcbEventLog.appendStream (Phase H of effect-stream-integration plan).
// Verifies that a Stream<Spec.event> can drive a single atomic append, and that
// the readStream → appendStream pipeline works end-to-end.

open AsyncTest
open AsyncTest.Expect
open DcbFixtures

describe("DcbEventLog.appendStream (in-memory adapter)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("appendStream writes all events from stream", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let stream = [
      DcbFixtures.ItemEventLog.ItemAdded({id: "as-w1", name: "Widget1"}),
      DcbFixtures.ItemEventLog.ItemAdded({id: "as-w1", name: "Widget2"}),
    ]->Stream.fromIterable
    let result = await ops.appendStream(stream)->Effect.runPromise
    let isOk = switch result {
    | Ok(_) => true
    | Error(_) => false
    }
    expect(isOk)->toBe(true)
    let read = await ops.read(~query=tagQuery("as-w1"))
    expect(read.events->Array.length)->toBe(2)
  })

  testPromise("appendStream on empty stream succeeds", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    // Empty stream → empty array append → storage returns Ok(position)
    let result = await ops.appendStream(Stream.empty)->Effect.runPromise
    let isOk = switch result {
    | Ok(_) => true
    | Error(_) => false
    }
    expect(isOk)->toBe(true)
  })

  testPromise("readStream → appendStream pipeline copies events", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append([DcbFixtures.ItemEventLog.ItemAdded({id: "as-src", name: "Source"})])
    // readStream returns sequencedEvent<event>; extract bare events for appendStream
    let srcStream =
      ops.readStream(~query=tagQuery("as-src"))->Stream.map(se => se.event)
    let _ = await ops.appendStream(srcStream)->Effect.runPromise
    let dst = await ops.read(~query=tagQuery("as-src"))
    // 1 original + 1 copy = 2 events for the same tag
    expect(dst.events->Array.length)->toBe(2)
  })
})
