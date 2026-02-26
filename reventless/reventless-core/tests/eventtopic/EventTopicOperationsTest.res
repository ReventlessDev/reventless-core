open Jest
open Expect
open EventTopicFixtures

module Ops = EventTopic_Operations.Make(
  ItemEventTopicSpec,
  {
    let publishJson = mockPublishJson
  },
)

let _ = beforeEach(() => reset())

describe("EventTopic_Operations:", () => {
  describe("publish", () => {
    testPromise("calls publishJson for each event", async () => {
      let events = [
        makeEvent'("item-1", ItemEventTopicSpec.ItemPublished({name: "Widget"})),
        makeEvent'("item-2", ItemEventTopicSpec.ItemRemoved({id: "item-2"})),
      ]
      await Ops.publish(events)
      expect(capturedCalls.contents->Array.length)->toBe(2)
    })

    testPromise("calls publishJson with correct service (id string)", async () => {
      let event' = makeEvent'("item-1", ItemEventTopicSpec.ItemPublished({name: "Widget"}))
      await Ops.publish([event'])
      let first = capturedCalls.contents->Array.getUnsafe(0)
      let (service, _, _) = first
      expect(service)->toBe("item-1")
    })

    testPromise("publishes empty array without error", async () => {
      await Ops.publish([])
      expect(capturedCalls.contents->Array.length)->toBe(0)
    })

    testPromise("encodes event with correct JSON structure", async () => {
      let event' = makeEvent'("item-1", ItemEventTopicSpec.ItemPublished({name: "Widget"}))
      await Ops.publish([event'])
      let (_, _, json) = capturedCalls.contents->Array.getUnsafe(0)
      // JSON should contain the event type info
      let hasExpectedFields =
        json->JSON.Decode.object->Option.map(d => d->Dict.has("event"))->Option.getOr(false) ||
        json->JSON.Decode.object->Option.map(d => d->Dict.has("id"))->Option.getOr(false)
      expect(hasExpectedFields)->toBe(true)
    })
  })
})
