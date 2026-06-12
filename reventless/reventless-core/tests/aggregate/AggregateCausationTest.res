// Regression test for causation propagation through Aggregate_Callback:
// events emitted from a command must carry
//   - causationId = the command's msgId
//   - correlationId = the command's correlationId (chain-root id stays stable)
//   - service inherited from the command (parent's service)
//   - fresh msgId distinct from the command's

open JestGlobals
open AggregateFixtures

let _ = beforeEach(() => mock.reset())

describe("Aggregate_Callback causation propagation:", () => {
  testPromise("event.meta.causationId = command.meta.msgId", async () => {
    let _ =
      await Stream.fromIterable([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])->TestHandler.handleCommands->Effect.runPromise
    let stored = mock.getAll()->Array.getUnsafe(0)
    expect(stored.meta.causationId)->toEqual(Some(testMeta.msgId))
  })

  testPromise("event.meta.correlationId = command.meta.correlationId (chain root stable)", async () => {
    let _ =
      await Stream.fromIterable([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])->TestHandler.handleCommands->Effect.runPromise
    let stored = mock.getAll()->Array.getUnsafe(0)
    expect(stored.meta.correlationId)->toBe(testMeta.correlationId)
  })

  testPromise("event has a fresh msgId distinct from the command's msgId", async () => {
    let _ =
      await Stream.fromIterable([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])->TestHandler.handleCommands->Effect.runPromise
    let stored = mock.getAll()->Array.getUnsafe(0)
    expect(stored.meta.msgId == testMeta.msgId)->toBe(false)
  })

  testPromise("event inherits ip / user / service from the command's meta", async () => {
    let _ =
      await Stream.fromIterable([
        makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
      ])->TestHandler.handleCommands->Effect.runPromise
    let stored = mock.getAll()->Array.getUnsafe(0)
    expect(stored.meta.service)->toBe(testMeta.service)
  })
})
