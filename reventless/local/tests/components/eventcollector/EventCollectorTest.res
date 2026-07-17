// Integration tests for EventCollector_Builder with in-memory channel.

open TestFixtures
open JestGlobals
open EventCollectorFixtures

describe("EventCollector (in-memory)", () => {
  // Two resolves needed (same as ReadModel E2E):
  //   1. eventCollector.operations chain — triggers EventCollectorChannel wiring
  //   2. topicResource.name — triggers inner resource.name.apply to register bus subscription
  let _ = beforeAllAsync(async () => {
    let _ = await eventCollector->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await topicResource.name->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEvents := []
  })

  testPromise("EventCollector component exists", async () => {
    let ops = await eventCollector->ReventlessCore.Component.operations->TestRunner.resolve
    // Verify the operations object has the expected enqueueEvent function
    expect(ops.enqueueEvent->typeof)->toBe("function")
  })

  testPromise("bus publishes events to topic subscribers", async () => {
    // The EventCollector itself doesn't expose a direct handler in our test setup —
    // verify the bus subscription mechanism works
    let received: ref<int> = ref(0)
    Bus.subscribeToEvents(topicName, async (_, _, _) => {
      received := received.contents + 1
    })
    let testEvent = JSON.Encode.object(Dict.fromArray([("type", JSON.Encode.string("TestEvent"))]))
    await Bus.publishEvent(topicName, "test", testMeta, testEvent)
    expect(received.contents)->toBe(1)
  })
})
