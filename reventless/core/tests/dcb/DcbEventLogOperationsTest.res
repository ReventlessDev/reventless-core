open JestGlobals

let mock = DcbFixtures.makeMockStorage()

module TestOps: DcbEventLog_Operations.Ops = {
  let name = "TestDcbEventLog"
  let serviceName = "TestDcbEventLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
}

module Ops = DcbEventLog_Operations.Make(TestOps)

// Verifies Phase 1.5 of Plan 03: the `service` carried on published events
// comes from `serviceName`, not `name`. Plugin_Builder relies on this to align
// `meta.service` with `allEventTopics`'s dict key.
module TestOpsAlt: DcbEventLog_Operations.Ops = {
  let name = "Catalog"
  let serviceName = "CatalogDcbEventLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
}
module OpsAlt = DcbEventLog_Operations.Make(TestOpsAlt)

let _ = beforeEach(() => mock.reset())

// Helper to encode a TestEventLogSpec event to a rawEvent for testing
let encodeEvent = (event: DcbFixtures.TestEventLogSpec.event): ReventlessInfra.DcbEventLog.rawEvent => {
  let json = event->S.reverseConvertToJsonOrThrow(DcbFixtures.TestEventLogSpec.eventSchema)
  let (eventType, data) = json->Message.splitMessage
  let tags = Reventless.DcbTag.extractTags(DcbFixtures.TestEventLogSpec.eventSchema, event)
  let meta = Message.generateMeta(~service="test")
  {eventType, data: JSON.Object(data), tags, meta}
}

// Helper to decode a rawSequencedEvent back to a TestEventLogSpec event
let decodeEvent = (raw: ReventlessInfra.DcbEventLog.rawSequencedEvent): DcbFixtures.TestEventLogSpec.event => {
  let json = Message.combineMessage(
    raw.eventType,
    raw.data->JSON.Decode.object->Option.getOr(Dict.make()),
  )
  json->S.parseJsonOrThrow(DcbFixtures.TestEventLogSpec.eventSchema)
}

describe("DcbEventLog_Operations:", () => {
  describe("round-trip (append then read)", () => {
    testPromise("ItemCreated preserves through round-trip", async () => {
      let event = DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})
      let rawEvent = encodeEvent(event)
      let _ = await Ops.append([rawEvent])
      let result = await Ops.read(~query=[{}])

      expect((
        result.events->Array.length,
        result.events->Array.get(0)->Option.map(se => decodeEvent(se)),
      ))->toEqual((1, Some(event)))
    })

    testPromise("CountUpdated with int tag preserves through round-trip", async () => {
      let event = DcbFixtures.TestEventLogSpec.CountUpdated({category: "electronics", amount: 42})
      let rawEvent = encodeEvent(event)
      let _ = await Ops.append([rawEvent])
      let result = await Ops.read(~query=[{}])

      expect(result.events->Array.get(0)->Option.map(se => decodeEvent(se)))->toEqual(Some(event))
    })

    testPromise("multiple events in single append all read back", async () => {
      let events = [
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "First"}),
        DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Second"}),
      ]
      let rawEvents = events->Array.map(encodeEvent)
      let _ = await Ops.append(rawEvents)
      let result = await Ops.read(~query=[{}])

      expect((
        result.events->Array.length,
        result.events->Array.map(se => decodeEvent(se)),
      ))->toEqual((2, events))
    })
  })

  describe("append", () => {
    testPromise("stores events and publishes to event topic", async () => {
      let event = DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})
      let result = await Ops.append([encodeEvent(event)])

      expect((
        Result.isOk(result),
        mock.getEvents()->Array.length,
        mock.publishedEvents.contents->Array.length,
      ))->toEqual((true, 1, 1))
    })

    testPromise("published events have correct service name", async () => {
      let _ = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})),
      ])

      expect(
        mock.publishedEvents.contents->Array.get(0)->Option.map(pe => pe.service),
      )->toEqual(Some("TestDcbEventLog"))
    })

    testPromise("service comes from Ops.serviceName, not Ops.name", async () => {
      let _ = await OpsAlt.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})),
      ])

      expect(
        mock.publishedEvents.contents->Array.get(0)->Option.map(pe => pe.service),
      )->toEqual(Some("CatalogDcbEventLog"))
    })

    testPromise("error from storage does not publish to event topic", async () => {
      mock.failNextAppends := 1
      let result = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})),
      ])

      expect((Result.isError(result), mock.publishedEvents.contents->Array.length))->toEqual((
        true,
        0,
      ))
    })

    testPromise("with condition (no conflict) succeeds", async () => {
      let _ = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})),
      ])
      let condition: Reventless.DcbTag.appendCondition = {
        query: [{eventTypes: ["ItemCreated"], tags: [{Reventless.DcbTag.key: "itemId", value: "item-1"}]}],
        after: "1",
      }
      let result = await Ops.append(
        [encodeEvent(DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Updated"}))],
        ~condition,
      )

      expect(Result.isOk(result))->toBe(true)
    })

    testPromise("multiple events all stored and published", async () => {
      let events = [
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "First"}),
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-2", name: "Second"}),
      ]
      let _ = await Ops.append(events->Array.map(encodeEvent))

      expect((
        mock.getEvents()->Array.length,
        mock.publishedEvents.contents->Array.length,
      ))->toEqual((2, 2))
    })
  })

  describe("read", () => {
    testPromise("returns headPosition from storage", async () => {
      let _ = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})),
      ])
      let result = await Ops.read(~query=[{}])

      expect(result.headPosition)->toEqual(Some("1"))
    })

    testPromise("with ~after parameter filters out earlier events", async () => {
      let _ = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "First"})),
      ])
      let _ = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Second"})),
      ])
      let result = await Ops.read(~query=[{}], ~after="1")

      expect((
        result.events->Array.length,
        result.events->Array.get(0)->Option.map(se => decodeEvent(se)),
      ))->toEqual((
        1,
        Some(DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Second"})),
      ))
    })

    testPromise("no matching events returns empty array", async () => {
      let _ = await Ops.append([
        encodeEvent(DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})),
      ])
      let result = await Ops.read(~query=[{eventTypes: ["NonExistent"]}])

      expect(result.events->Array.length)->toEqual(0)
    })
  })
})
