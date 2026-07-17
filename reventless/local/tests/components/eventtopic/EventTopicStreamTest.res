// Tests for EventTopic.publishJsonStream (Phase I of effect-stream-integration plan).
// Verifies that a Stream<publishJsonStreamItem> drives publishing without collecting into an array.

open TestFixtures
open JestGlobals
open EventTopicStreamFixtures

describe("EventTopic.publishJsonStream", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await evtTopic->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    received := 0
  })

  testPromise("streams 2 events to all subscribers", async () => {
    let ops = await evtTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let stream = [
      ({service: "svc", meta: testMeta, json: JSON.parseOrThrow("{\"ev\":1}")}: ReventlessInfra.EventTopic.publishJsonStreamItem),
      {service: "svc", meta: testMeta, json: JSON.parseOrThrow("{\"ev\":2}")},
    ]->Stream.fromIterable
    let _ = await ops.publishJsonStream(stream)->Effect.runPromise
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    expect(received.contents)->toBe(2)
  })

  testPromise("empty stream publishes nothing to subscribers", async () => {
    let ops = await evtTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.publishJsonStream(Stream.empty)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(received.contents)->toBe(0)
  })
})
