open AsyncTest
open AsyncTest.Expect
open SideEffectHandlerFixtures

let _ = beforeEach(() => reset())

describe("SideEffectHandler_Callback.eventsHandler:", () => {
  describe("event matching registered side effect", () => {
    testPromise("execute called with decoded id and event", async () => {
      let event = TestSource.SomethingHappened({value: "hello"})
      let eventJson = makeEventJson("entity-1", event)
      await TestHandler.eventsHandler([eventJson])
      let call = capturedExecuteCalls.contents->Array.getUnsafe(0)
      expect((call.id, call.event))->toEqual(("entity-1", event))
    })
  })

  describe("event with no matching source name", () => {
    testPromise("execute not called, no error", async () => {
      let event = TestSource.SomethingHappened({value: "ignored"})
      let eventJson = makeEventJson(~service="UnknownService", "entity-1", event)
      await TestHandler.eventsHandler([eventJson])
      expect(capturedExecuteCalls.contents->Array.length)->toBe(0)
    })
  })

  describe("event with malformed JSON", () => {
    testPromise("caught gracefully — does not throw, execute not called", async () => {
      let invalidJson = JSON.Encode.string("not-an-object")
      await TestHandler.eventsHandler([invalidJson])
      expect(capturedExecuteCalls.contents->Array.length)->toBe(0)
    })
  })

  describe("execute throws", () => {
    testPromise("error caught per-event, other events still processed", async () => {
      // First event causes execute to throw; second event processes normally
      executeThrowOnCall := 1
      let event = TestSource.SomethingHappened({value: "v"})
      let event1 = makeEventJson("entity-1", event)
      let event2 = makeEventJson("entity-2", event)
      await TestHandler.eventsHandler([event1, event2])
      // entity-2 should still be captured (first event threw)
      expect(capturedExecuteCalls.contents->Array.length)->toBe(1)
      expect((capturedExecuteCalls.contents->Array.getUnsafe(0)).id)->toBe("entity-2")
    })
  })

  describe("multiple events in batch", () => {
    testPromise("each handled independently", async () => {
      let event = TestSource.SomethingHappened({value: "v"})
      let events = ["entity-1", "entity-2", "entity-3"]->Array.map(id => makeEventJson(id, event))
      await TestHandler.eventsHandler(events)
      expect(capturedExecuteCalls.contents->Array.length)->toBe(3)
    })
  })
})
