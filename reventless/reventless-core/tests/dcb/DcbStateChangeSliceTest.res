open Jest
open Expect

let mock = DcbFixtures.makeMockStorage()

module TestDcbOps: DcbEventLog_Operations.Ops with module Spec = DcbFixtures.TestEventLogSpec = {
  module Spec = DcbFixtures.TestEventLogSpec
  let name = "TestDcbEventLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
}

module EventLogOps = DcbEventLog_Operations.Make(DcbFixtures.TestEventLogSpec, TestDcbOps)

let testDcbEventLog: DcbEventLog.operations<DcbFixtures.TestEventLogSpec.event> = {
  read: EventLogOps.read,
  append: EventLogOps.append,
  readStream: EventLogOps.readStream,
}

module TestHandler = StateChangeSlice_Callback.Make(DcbFixtures.TestCommandSpec)

let makeTopicItem = (reference, command): CommandTopic.topicItem<
  Message.command'<Reventless.Id.String.t, DcbFixtures.TestCommandSpec.command>,
> => {
  command: {
    id: Reventless.Id.String.makeFromString("cmd-" ++ reference),
    meta: DcbFixtures.testMeta,
    command,
  },
  reference,
}

let _ = beforeEach(() => mock.reset())

describe("StateChangeSlice_Callback:", () => {
  describe("handleCommands - happy path", () => {
    testPromise("CreateItem on empty log succeeds", async () => {
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
      ])

      expect((
        results,
        mock.getEvents()->Array.length,
        mock.publishedEvents.contents->Array.length,
      ))->toEqual(([Ok("ref-1")], 1, 1))
    })

    testPromise("stored event has correct tags", async () => {
      let _ = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
      ])
      let storedEvent = mock.getEvents()->Array.getUnsafe(0)

      expect(storedEvent.tags)->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}])
    })
  })

  describe("handleCommands - decide returns Ok([])", () => {
    testPromise("NoOp returns Ok without storing events", async () => {
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-noop", DcbFixtures.TestCommandSpec.NoOp),
      ])

      expect((results, mock.getEvents()->Array.length))->toEqual(([Ok("ref-noop")], 0))
    })
  })

  describe("handleCommands - decide returns Error", () => {
    testPromise("CreateItem when item exists returns Error", async () => {
      // First create the item
      let _ = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
      ])
      // Try to create again
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-2", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Duplicate"})),
      ])

      expect(results)->toEqual([Error("ref-2")])
    })
  })

  describe("handleCommands - retry on conflict", () => {
    testPromise("retries and succeeds after 1 append failure", async () => {
      mock.failNextAppends := 1
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
      ])

      expect((results, mock.getEvents()->Array.length))->toEqual(([Ok("ref-1")], 1))
    })

    testPromise("returns Error after retries exhausted (4 failures)", async () => {
      mock.failNextAppends := 4
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
      ])

      expect((results, mock.getEvents()->Array.length))->toEqual(([Error("ref-1")], 0))
    })
  })

  describe("handleCommands - conditional append", () => {
    testPromise("RenameItem after CreateItem uses headPosition in condition", async () => {
      let _ = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
      ])
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem(
          "ref-2",
          DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-1", newName: "Updated"}),
        ),
      ])

      expect((results, mock.getEvents()->Array.length))->toEqual(([Ok("ref-2")], 2))
    })
  })

  describe("handleCommands - batch", () => {
    testPromise("multiple successful commands", async () => {
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "First"})),
        makeTopicItem("ref-2", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-2", name: "Second"})),
      ])

      expect(results)->toEqual([Ok("ref-1"), Ok("ref-2")])
    })

    testPromise("mixed success and failure", async () => {
      // Create item-1 first
      let _ = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-0", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Existing"})),
      ])
      // Batch: create item-2 (ok) and duplicate item-1 (error)
      let results = await TestHandler.handleCommands(testDcbEventLog, [
        makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-2", name: "New"})),
        makeTopicItem(
          "ref-2",
          DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Duplicate"}),
        ),
      ])

      expect(results)->toEqual([Ok("ref-1"), Error("ref-2")])
    })

    testPromise("empty batch returns empty array", async () => {
      let results = await TestHandler.handleCommands(testDcbEventLog, [])

      expect(results)->toEqual([])
    })
  })
})
