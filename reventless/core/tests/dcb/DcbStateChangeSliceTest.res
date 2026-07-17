open JestGlobals

let mock = DcbFixtures.makeMockStorage()

module TestDcbOps: DcbEventLog_Operations.Ops = {
  let name = "TestDcbEventLog"
  let serviceName = "TestDcbEventLog"
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

// Per-slice `readConsistency` overrides: same types/behavior as TestCommandSpec,
// only the build-time consistency mode differs. The default (TestCommandSpec) is
// `EscalateOnRetry`; these force strong / eventual on every attempt.
module StrongSpec = {
  include DcbFixtures.TestCommandSpec
  let readConsistency = Reventless.ReadConsistency.AlwaysStrong
}
module EventualSpec = {
  include DcbFixtures.TestCommandSpec
  let readConsistency = Reventless.ReadConsistency.AlwaysEventual
}
module StrongHandler = StateChangeSlice_Callback.Make(StrongSpec, TestCommandBehavior)
module EventualHandler = StateChangeSlice_Callback.Make(EventualSpec, TestCommandBehavior)

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

let _ = beforeEach(() => {
  mock.reset()
  // The projection cache is keyed on durable positions; the mock storage is wiped
  // each test, so the cache must be flushed too or a prior test's snapshot leaks.
  TestHandler.resetCache()
  StrongHandler.resetCache()
  EventualHandler.resetCache()
})

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

    testPromise("stored event carries only its entity tags (no framework provenance tag)", async () => {
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise
      let storedEvent = mock.getEvents()->Array.getUnsafe(0)

      // No `originatorSlice` (or any other) metadata tag is smuggled into the tag
      // set — a stored event's tags are exactly its DCB entity tags, so the
      // composite read/write keys stay aligned. See
      // docs/analysis/dcb-event-provenance-and-metadata.md.
      expect(storedEvent.tags)->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}])
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

  describe("handleCommands - read consistency (eventual-first, strong-on-retry)", () => {
    testPromise("a conflict-free command reads eventually-consistent (no strong read)", async () => {
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      // Single attempt → single read, eventual.
      expect(mock.readStrongConsistency.contents)->toEqual([false])
    })

    testPromise("escalates to strong consistency on retry after a conflict", async () => {
      mock.failNextAppends := 1
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      // First attempt eventual, retry strong.
      expect(mock.readStrongConsistency.contents)->toEqual([false, true])
    })

    testPromise("every retry after the first is strong (2 failures)", async () => {
      mock.failNextAppends := 2
      let _ = await TestHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      expect(mock.readStrongConsistency.contents)->toEqual([false, true, true])
    })
  })

  describe("handleCommands - read consistency (per-slice override)", () => {
    testPromise("AlwaysStrong reads strong on the first attempt", async () => {
      let _ = await StrongHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      // No escalation step — strong from the start.
      expect(mock.readStrongConsistency.contents)->toEqual([true])
    })

    testPromise("AlwaysStrong stays strong across retries (2 failures)", async () => {
      mock.failNextAppends := 2
      let _ = await StrongHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      expect(mock.readStrongConsistency.contents)->toEqual([true, true, true])
    })

    testPromise("AlwaysEventual never reads strong, even on retry (2 failures)", async () => {
      mock.failNextAppends := 2
      let _ = await EventualHandler.handleCommands(
        testDcbEventLog,
        Stream.fromIterable([
          makeTopicItem("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"})),
        ]),
      )->Effect.runPromise

      expect(mock.readStrongConsistency.contents)->toEqual([false, false, false])
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

  describe("handleCommands - projection cache", () => {
    // The decision-model projection cache (StateChangeSlice_Callback) caches the
    // `(decisionState, readHead)` per query. A warm same-entity command then reads
    // only events after `readHead` — observable here via `mock.readAfters`
    // (Some(_) = delta read, None = full read).
    testPromise("a third same-entity command reads only the delta", async () => {
      let run = (reference, command) =>
        TestHandler.handleCommands(
          testDcbEventLog,
          Stream.fromIterable([makeTopicItem(reference, command)]),
        )->Effect.runPromise

      let _ = await run("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "A"}))
      let _ = await run("ref-2", DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-1", newName: "B"}))
      let r3 = await run("ref-3", DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-1", newName: "C"}))

      // Read 1 (create, empty log) and read 2 (rename, head was None) are full
      // reads; read 3 hits the cache primed by read 2 and reads after position "1".
      expect((r3, mock.readAfters.contents, mock.getEvents()->Array.length))->toEqual((
        [Ok("ref-3")],
        [None, None, Some("1")],
        3,
      ))
    })

    testPromise("a different entity does not hit another entity's cache (full read)", async () => {
      let run = (reference, command) =>
        TestHandler.handleCommands(
          testDcbEventLog,
          Stream.fromIterable([makeTopicItem(reference, command)]),
        )->Effect.runPromise

      let _ = await run("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "A"}))
      let _ = await run("ref-2", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-2", name: "B"}))

      // item-2's query is a distinct cache key → cold full read (after=None).
      expect(mock.readAfters.contents)->toEqual([None, None])
    })

    testPromise("conflict re-seeds the cache so the retry reads the delta", async () => {
      let run = (reference, command) =>
        TestHandler.handleCommands(
          testDcbEventLog,
          Stream.fromIterable([makeTopicItem(reference, command)]),
        )->Effect.runPromise

      let _ = await run("ref-1", DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "A"}))
      // Force one append failure: the retry must re-seed from the just-read
      // snapshot and read only the delta after position "1".
      mock.failNextAppends := 1
      let r2 = await run("ref-2", DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-1", newName: "B"}))

      expect((r2, mock.readAfters.contents, mock.getEvents()->Array.length))->toEqual((
        [Ok("ref-2")],
        [None, None, Some("1")],
        2,
      ))
    })
  })
})
