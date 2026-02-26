open AsyncTest
open AsyncTest.Expect
open EventLogFixtures

// Wire up EventLog_Operations with mock storage and mock EventTopic
module TestOps: EventLog_Operations.Ops with module Spec = ItemEventLogSpec = {
  module Spec = ItemEventLogSpec
  module EventTopic = MockEventTopic
  let eventTopic = mockEventTopicOps
  let storage = mockStorage
}

module Ops = EventLog_Operations.Make(ItemEventLogSpec, TestOps)

let _ = beforeEach(() => reset())

describe("EventLog_Operations:", () => {
  describe("append", () => {
    testPromise("stores encoded events in storage", async () => {
      let event = ItemEventLogSpec.ItemCreated({name: "Widget"})
      let event' = makeEvent'("item-1", event)
      let _ = await Ops.append(1, "item-1", [event'])
      let stored = storedEvents.contents->Dict.get("item-1")->Option.getOr([])
      expect(stored->Array.length)->toBe(1)
    })

    testPromise("publishes events to event topic", async () => {
      let event = ItemEventLogSpec.ItemCreated({name: "Widget"})
      let event' = makeEvent'("item-1", event)
      let _ = await Ops.append(1, "item-1", [event'])
      expect(capturedPublishes.contents->Array.length)->toBe(1)
    })

    testPromise("storage failure returns Error result", async () => {
      failNextAppend := true
      let event = ItemEventLogSpec.ItemCreated({name: "Widget"})
      let event' = makeEvent'("item-1", event)
      let result = await Ops.append(1, "item-1", [event'])
      // When storage returns Error (not throws), the operation still publishes
      // but the Error result is propagated back to the caller.
      expect(Result.isError(result))->toBe(true)
    })

    testPromise("multiple events all stored and published", async () => {
      let events' = [
        makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "First"})),
        makeEvent'("item-2", ItemEventLogSpec.ItemCreated({name: "Second"})),
      ]
      let _ = await Ops.append(1, "agg-1", events')
      let stored = storedEvents.contents->Dict.get("agg-1")->Option.getOr([])
      expect((stored->Array.length, capturedPublishes.contents->Array.length))->toEqual((2, 2))
    })

    testPromise("returns Ok on success", async () => {
      let event' = makeEvent'("item-1", ItemEventLogSpec.ItemCreated({name: "Widget"}))
      let result = await Ops.append(1, "item-1", [event'])
      expect(Result.isOk(result))->toBe(true)
    })
  })

  describe("replay", () => {
    testPromise("returns empty array for unknown id", async () => {
      let events = await Ops.replay("unknown-id")
      expect(events->Array.length)->toBe(0)
    })

    testPromise("decodes stored events back to typed events", async () => {
      let event = ItemEventLogSpec.ItemCreated({name: "Widget"})
      let event' = makeEvent'("item-1", event)
      let _ = await Ops.append(1, "item-1", [event'])
      let replayed = await Ops.replay("item-1")
      expect(replayed->Array.length)->toBe(1)
      let first = replayed->Array.getUnsafe(0)
      expect(first)->toEqual(event)
    })

    testPromise("decodes multiple events in order", async () => {
      let events = [
        ItemEventLogSpec.ItemCreated({name: "Widget"}),
        ItemEventLogSpec.ItemDeleted({id: "item-1"}),
      ]
      let events' = events->Array.map(event => makeEvent'("item-1", event))
      let _ = await Ops.append(1, "item-1", events')
      let replayed = await Ops.replay("item-1")
      expect(replayed->Array.length)->toBe(2)
      expect(replayed)->toEqual(events)
    })

    testPromise("separate aggregates have independent event logs", async () => {
      let _ = await Ops.append(1, "agg-A", [makeEvent'("agg-A", ItemEventLogSpec.ItemCreated({name: "A"}))])
      let _ = await Ops.append(1, "agg-B", [makeEvent'("agg-B", ItemEventLogSpec.ItemDeleted({id: "B"}))])
      let eventsA = await Ops.replay("agg-A")
      let eventsB = await Ops.replay("agg-B")
      expect((eventsA->Array.length, eventsB->Array.length))->toEqual((1, 1))
    })
  })
})
