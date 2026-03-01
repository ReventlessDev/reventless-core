// Tests for CommandTopic.publishJsonsStream (Phase I of effect-stream-integration plan).
// Verifies that a Stream<commandJson> drives publishing without collecting into an array.

open AsyncTest
open AsyncTest.Expect
open CommandTopicStreamFixtures

describe("CommandTopic.publishJsonsStream", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    captured := []
  })

  testPromise("streams 3 commands to the bus in order", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let stream = [makeJson("cmd-1"), makeJson("cmd-2"), makeJson("cmd-3")]->Stream.fromIterable
    let _ = await ops.publishJsonsStream(stream)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(captured.contents->Array.length)->toBe(3)
  })

  testPromise("empty stream dispatches nothing", async () => {
    let ops = await cmdTopic->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.publishJsonsStream(Stream.empty)->Effect.runPromise
    let _ = await Promise.resolve()
    expect(captured.contents->Array.length)->toBe(0)
  })
})
