open Jest
open Expect

let mock = DcbFixtures.makeMockStorage()

module TestOps: DcbEventLog_Operations.Ops with module Spec = DcbFixtures.TestEventLogSpec = {
  module Spec = DcbFixtures.TestEventLogSpec
  let name = "TestDcbEventLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
}

module Ops = DcbEventLog_Operations.Make(DcbFixtures.TestEventLogSpec, TestOps)

let _ = beforeEach(() => mock.reset())

describe("DcbEventLog_Operations:", () => {
  describe("round-trip (append then read)", () => {
    testPromise("ItemCreated preserves through round-trip", async () => {
      let event = DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})
      let _ = await Ops.append([event])
      let result = await Ops.read(~query=[{}])

      expect((
        result.events->Array.length,
        result.events->Array.get(0)->Option.map(se => se.event),
      ))->toEqual((1, Some(event)))
    })

    testPromise("CountUpdated with int tag preserves through round-trip", async () => {
      let event = DcbFixtures.TestEventLogSpec.CountUpdated({category: "electronics", amount: 42})
      let _ = await Ops.append([event])
      let result = await Ops.read(~query=[{}])

      expect(result.events->Array.get(0)->Option.map(se => se.event))->toEqual(Some(event))
    })

    testPromise("multiple events in single append all read back", async () => {
      let events = [
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "First"}),
        DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Second"}),
      ]
      let _ = await Ops.append(events)
      let result = await Ops.read(~query=[{}])

      expect((
        result.events->Array.length,
        result.events->Array.map(se => se.event),
      ))->toEqual((2, events))
    })
  })

  describe("append", () => {
    testPromise("stores events and publishes to event topic", async () => {
      let event = DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"})
      let result = await Ops.append([event])

      expect((
        Result.isOk(result),
        mock.getEvents()->Array.length,
        mock.publishedEvents.contents->Array.length,
      ))->toEqual((true, 1, 1))
    })

    testPromise("published events have correct service name", async () => {
      let _ = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
      ])

      expect(
        mock.publishedEvents.contents->Array.get(0)->Option.map(pe => pe.service),
      )->toEqual(Some("TestDcbEventLog"))
    })

    testPromise("error from storage does not publish to event topic", async () => {
      mock.failNextAppends := 1
      let result = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
      ])

      expect((Result.isError(result), mock.publishedEvents.contents->Array.length))->toEqual((
        true,
        0,
      ))
    })

    testPromise("with condition (no conflict) succeeds", async () => {
      let _ = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
      ])
      let condition: DcbTag.appendCondition = {
        query: [{eventTypes: ["ItemCreated"], tags: [{DcbTag.key: "itemId", value: "item-1"}]}],
        after: "1",
      }
      let result = await Ops.append(
        [DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Updated"})],
        ~condition,
      )

      expect(Result.isOk(result))->toBe(true)
    })

    testPromise("multiple events all stored and published", async () => {
      let events = [
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "First"}),
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-2", name: "Second"}),
      ]
      let _ = await Ops.append(events)

      expect((
        mock.getEvents()->Array.length,
        mock.publishedEvents.contents->Array.length,
      ))->toEqual((2, 2))
    })
  })

  describe("read", () => {
    testPromise("returns headPosition from storage", async () => {
      let _ = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
      ])
      let result = await Ops.read(~query=[{}])

      expect(result.headPosition)->toEqual(Some("1"))
    })

    testPromise("with ~after parameter filters out earlier events", async () => {
      let _ = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "First"}),
      ])
      let _ = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Second"}),
      ])
      let result = await Ops.read(~query=[{}], ~after="1")

      expect((
        result.events->Array.length,
        result.events->Array.get(0)->Option.map(se => se.event),
      ))->toEqual((
        1,
        Some(DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-1", newName: "Second"})),
      ))
    })

    testPromise("no matching events returns empty array", async () => {
      let _ = await Ops.append([
        DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
      ])
      let result = await Ops.read(~query=[{eventTypes: ["NonExistent"]}])

      expect(result.events->Array.length)->toEqual(0)
    })
  })
})
