open JestGlobals
open EventLogFixtures

// Wire up EventLog_Operations with the same mock storage and EventTopic as the
// basic operations tests — but use the counter-based transient failure mock.
module TestOps: EventLog_Operations.Ops with module Spec = ItemEventLogSpec = {
  module Spec = ItemEventLogSpec
  module EventTopic = MockEventTopic
  let eventTopic = mockEventTopicOps
  let storage = mockStorage
}

module Ops = EventLog_Operations.Make(ItemEventLogSpec, TestOps)

let _ = beforeEach(() => reset())

describe("EventLog_Operations — retry:", () => {
  describe("isTransient predicate:", () => {
    testPromise("ThrottlingException is transient", async () => {
      expect(EventLog_Operations.isTransient("ThrottlingException: Rate exceeded"))->toBe(true)
    })

    testPromise("ProvisionedThroughputExceededException is transient", async () => {
      expect(
        EventLog_Operations.isTransient("ProvisionedThroughputExceededException"),
      )->toBe(true)
    })

    testPromise("ServiceUnavailable is transient", async () => {
      expect(EventLog_Operations.isTransient("ServiceUnavailable"))->toBe(true)
    })

    testPromise("RequestLimitExceeded is transient", async () => {
      expect(EventLog_Operations.isTransient("RequestLimitExceeded"))->toBe(true)
    })

    testPromise("InternalServerError is transient", async () => {
      expect(EventLog_Operations.isTransient("InternalServerError: something went wrong"))->toBe(
        true,
      )
    })

    testPromise("ValidationException is not transient", async () => {
      expect(EventLog_Operations.isTransient("ValidationException: invalid field"))->toBe(false)
    })

    testPromise("generic mock storage failure is not transient", async () => {
      expect(EventLog_Operations.isTransient("mock storage failure"))->toBe(false)
    })
  })

  describe("permanent storage failure:", () => {
    testPromise("returns Error immediately without retry", async () => {
      failNextAppend := true // "mock storage failure" — not transient, no retry
      let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
      let result = await Ops.append(1, "item-1", [event'])
      expect(Result.isError(result))->toBe(true)
      // Exactly one attempt — permanent error is not retried
      expect(appendCallCount.contents)->toBe(1)
    })

    testPromise("does not publish events after permanent storage failure", async () => {
      failNextAppend := true
      let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
      let _ = await Ops.append(1, "item-1", [event'])
      expect(capturedPublishes.contents->Array.length)->toBe(0)
    })
  })

  describe("transient storage failure — retry:", () => {
    testPromise("1 transient failure retries and returns Ok", async () => {
      failNextAppendsWithTransient := 1
      let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
      let result = await Ops.append(1, "item-1", [event'])
      expect(Result.isOk(result))->toBe(true)
      // 1 initial attempt + 1 retry = 2 total calls to storage.append
      expect(appendCallCount.contents)->toBe(2)
    })

    testPromise("events are stored and published after successful retry", async () => {
      failNextAppendsWithTransient := 1
      let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
      let _ = await Ops.append(1, "item-1", [event'])
      let stored = storedEvents.contents->Dict.get("item-1")->Option.getOr([])
      expect(stored->Array.length)->toBe(1)
      expect(capturedPublishes.contents->Array.length)->toBe(1)
    })

    testPromise("2 transient failures retry twice and return Ok", async () => {
      failNextAppendsWithTransient := 2
      let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
      let result = await Ops.append(1, "item-1", [event'])
      expect(Result.isOk(result))->toBe(true)
      // 1 initial + 2 retries = 3 total calls
      expect(appendCallCount.contents)->toBe(3)
    })
  })

  describe("retry exhaustion:", () => {
    // The retry schedule allows up to 5 retries (recurs(5)).
    // 6 transient failures exhaust all retries; the append returns Error.
    //
    // Timing: exponential backoff (100ms base) + jitter (0–100% extra per step).
    //   Worst case: 200+400+800+1600+3200 ≈ 6 200 ms.
    //   A 12-second timeout provides 2× headroom above the jitter ceiling.
    testPromiseWithTimeout(
      "6 transient failures exhaust 5 retries and return Error",
      async () => {
        failNextAppendsWithTransient := 6
        let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
        let result = await Ops.append(1, "item-1", [event'])
        expect(Result.isError(result))->toBe(true)
        // 1 initial attempt + 5 retries = 6 total calls to storage.append
        expect(appendCallCount.contents)->toBe(6)
        // No events published after exhaustion
        expect(capturedPublishes.contents->Array.length)->toBe(0)
      },
      12000,
    )
  })
})
