open Jest
open Expect

let mock = DcbFixtures.makeMockStorage()

module TestDcbOps: DcbEventLog_Operations.Ops = {
  let name = "TestDcbEventLog"
  let storage = mock.operations
  let publishJson = mock.mockPublishJson
}

module EventLogOps = DcbEventLog_Operations.Make(TestDcbOps)

let testDcbEventLog: DcbEventLog.operations = {
  read: EventLogOps.read,
  append: EventLogOps.append,
  readStream: EventLogOps.readStream,
  appendStream: EventLogOps.appendStream,
}

module TestCommandBehavior = {
  type state = DcbFixtures.TestCommandSpec.state
  let initialState = DcbFixtures.TestCommandSpec.initialState
  let evolve = DcbFixtures.TestCommandSpec.evolve
  let decide = DcbFixtures.TestCommandSpec.decide
  let moduleUrl = DcbFixtures.TestCommandSpec.moduleUrl
}
module TestHandler = StateChangeSlice_Callback.Make(
  DcbFixtures.TestCommandSpec,
  TestCommandBehavior,
)

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
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      expect((
        results,
        mock.getEvents()->Array.length,
        mock.publishedEvents.contents->Array.length,
      ))->toEqual(([Ok("ref-1")], 1, 1))
    })

    testPromise("stored event has correct tags", async () => {
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise
      let storedEvent = mock.getEvents()->Array.getUnsafe(0)

      expect(storedEvent.tags)->toEqual([
        {Reventless.DcbTag.key: "itemId", value: "item-1"},
        {Reventless.DcbTag.key: "originatorSlice", value: "TestStateChangeSlice"},
      ])
    })
  })

  describe("handleCommands - decide returns Ok([])", () => {
    testPromise("NoOp returns Ok without storing events", async () => {
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([makeTopicItem("ref-noop", DcbFixtures.TestCommandSpec.NoOp)]),
      )->Effect.runPromise

      expect((results, mock.getEvents()->Array.length))->toEqual(([Ok("ref-noop")], 0))
    })
  })

  describe("handleCommands - decide returns Error", () => {
    testPromise("CreateItem when item exists returns Ok (business-rule violations ACK, not NACK)", async () => {
      // First create the item
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise
      // Try to create again — decide returns Error, but handler returns Ok("rejected") to avoid infinite SQS retry
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-2", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Duplicate"})),
        ]),
      )->Effect.runPromise

      expect(results)->toEqual([Ok("ref-2")])
    })
  })

  describe("handleCommands - retry on conflict", () => {
    testPromise("retries and succeeds after 1 append failure", async () => {
      mock.failNextAppends := 1
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      expect((results, mock.getEvents()->Array.length))->toEqual(([Ok("ref-1")], 1))
    })

    testPromise("returns Error after retries exhausted (4 failures)", async () => {
      mock.failNextAppends := 4
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      expect((results, mock.getEvents()->Array.length))->toEqual(([Error("ref-1")], 0))
    })
  })

  describe("handleCommands - conditional append", () => {
    testPromise("RenameItem after CreateItem uses headPosition in condition", async () => {
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem(
            "ref-2",
            DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-1", newName: "Updated"}),
          ),
        ]),
      )->Effect.runPromise

      expect((results, mock.getEvents()->Array.length))->toEqual(([Ok("ref-2")], 2))
    })
  })

  describe("handleCommands - batch", () => {
    testPromise("multiple successful commands", async () => {
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "First"})),
          makeTopicItem("ref-2", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-2", name: "Second"})),
        ]),
      )->Effect.runPromise

      expect(results)->toEqual([Ok("ref-1"), Ok("ref-2")])
    })

    testPromise("mixed: new item succeeds, duplicate item ACKs as Ok (business-rule violation)", async () => {
      // Create item-1 first
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-0", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Existing"})),
        ]),
      )->Effect.runPromise
      // Batch: create item-2 (ok) and duplicate item-1 (business-rule violation → Ok, not Error)
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-2", name: "New"})),
          makeTopicItem(
            "ref-2",
            DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Duplicate"}),
          ),
        ]),
      )->Effect.runPromise

      expect(results)->toEqual([Ok("ref-1"), Ok("ref-2")])
    })

    testPromise("empty batch returns empty array", async () => {
      let results = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([]),
      )->Effect.runPromise

      expect(results)->toEqual([])
    })
  })
})
