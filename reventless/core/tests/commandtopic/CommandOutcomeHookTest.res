// The command-outcome hook, at the property the side-channels don't have: it fires on the
// fire-and-forget dispatch path — no acceptedResultChannel/rejectedResultChannel is installed
// anywhere in this file — for both write-side component kinds, carrying the owning component
// and telling a domain rejection apart from an infrastructure failure.

open JestGlobals

// ── StateChangeSlice arm (the aggregate arm reuses AggregateFixtures as-is) ──

let dcbMock = DcbFixtures.makeMockStorage()

module TestDcbOps: DcbEventLog_Operations.Ops = {
  let name = "TestDcbEventLog"
  let serviceName = "TestDcbEventLog"
  let storage = dcbMock.operations
  let publishJson = dcbMock.mockPublishJson
}

module EventLogOps = DcbEventLog_Operations.Make(TestDcbOps)

let dcbEventLog: DcbEventLog.operations = {
  read: EventLogOps.read,
  append: EventLogOps.append,
  readStream: EventLogOps.readStream,
  appendStream: EventLogOps.appendStream,
}

module SliceBehavior = {
  type state = DcbFixtures.TestCommandSpec.state
  let initialState = DcbFixtures.TestCommandSpec.initialState
  let evolve = DcbFixtures.TestCommandSpec.evolve
  let decide = DcbFixtures.TestCommandSpec.decide
  let moduleUrl = DcbFixtures.TestCommandSpec.moduleUrl
}

module SliceHandler = StateChangeSlice_Callback.Make(DcbFixtures.TestCommandSpec, SliceBehavior)

let sliceItem = (reference, command): CommandTopic.topicItem<
  Message.command'<Reventless.Id.String.t, DcbFixtures.TestCommandSpec.command>,
> => {
  command: {
    id: Reventless.Id.String.makeFromString("cmd-" ++ reference),
    meta: DcbFixtures.testMeta,
    command,
  },
  reference,
}

let runSlice = (reference, command) =>
  SliceHandler.handleCommands(dcbEventLog, Stream.fromIterable([sliceItem(reference, command)]))
  ->Effect.runPromise

let runAgg = (~aggId="agg-1", reference, command) =>
  Stream.fromIterable([AggregateFixtures.makeTopicItem(~aggId, reference, command)])
  ->AggregateFixtures.TestHandler.handleCommands
  ->Effect.runPromise

// ── Capture ──

let observed: ref<array<CommandTopic_Helpers.commandOutcomeReport>> = ref([])

// Flattened for readable assertions: (component, reference, disposition, errorCode, eventCount).
let seen = () =>
  observed.contents->Array.map(r =>
    switch r.outcome {
    | OutcomeAccepted({eventCount}) => (r.component, r.reference, "accepted", "", eventCount)
    | OutcomeRejected({errorCode, cause}) => (
        r.component,
        r.reference,
        switch cause {
        | DomainRejection => "rejected/domain"
        | InfrastructureFailure => "rejected/infrastructure"
        },
        errorCode,
        0,
      )
    }
  )

let record = () =>
  CommandTopic_Helpers.registerCommandOutcome(r =>
    observed := observed.contents->Array.concat([r])
  )

let _ = beforeEach(() => {
  AggregateFixtures.mock.reset()
  AggregateFixtures.TestHandler.resetCache()
  dcbMock.reset()
  SliceHandler.resetCache()
  observed := []
  CommandTopic_Helpers.clearCommandOutcome()
  RuntimeExtension.reset()
})

describe("CommandTopic command-outcome hook:", () => {
  describe("aggregate", () => {
    testPromise("observes an accepted command with no side-channel installed", async () => {
      record()
      let results = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      expect(results)->toEqual([Ok("ref-1")])
      expect(seen())->toEqual([("TestAggregate", "ref-1", "accepted", "", 1)])
    })

    testPromise("carries the entity id of an accepted command", async () => {
      record()
      let _ = await runAgg(~aggId="agg-7", "ref-1", AggregateFixtures.AggSpec.Create({name: "W"}))

      let entityId = switch (observed.contents->Array.getUnsafe(0)).outcome {
      | OutcomeAccepted({entityId}) => entityId
      | OutcomeRejected(_) => None
      }
      expect(entityId)->toEqual(Some("agg-7"))
    })

    testPromise("reports a decide rejection as domain, with the declared error code", async () => {
      // Seed before registering, so only the second (rejected) Create is observed.
      let _ = await runAgg("ref-seed", AggregateFixtures.AggSpec.Create({name: "Widget"}))
      record()
      let results = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      expect(results)->toEqual([Ok("ref-1")])
      expect(seen())->toEqual([
        ("TestAggregate", "ref-1", "rejected/domain", "AlreadyExists", 0),
      ])
    })

    testPromise("reports a failed append as infrastructure, not a domain rejection", async () => {
      record()
      AggregateFixtures.mock.failNextAppend := true
      let _ = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      // `decide` said Ok here — the store is what failed, and the hook has to say so.
      expect(seen())->toEqual([
        ("TestAggregate", "ref-1", "rejected/infrastructure", "AppendFailed", 0),
      ])
    })

    testPromise("observes every command of a mixed batch", async () => {
      let _ = await runAgg("ref-seed", AggregateFixtures.AggSpec.Create({name: "Widget"}))
      record()
      let _ =
        await Stream.fromIterable([
          AggregateFixtures.makeTopicItem("ref-1", AggregateFixtures.AggSpec.Rename({newName: "A"})),
          AggregateFixtures.makeTopicItem("ref-2", AggregateFixtures.AggSpec.Create({name: "B"})),
          AggregateFixtures.makeTopicItem("ref-3", AggregateFixtures.AggSpec.Rename({newName: "C"})),
        ])
        ->AggregateFixtures.TestHandler.handleCommands
        ->Effect.runPromise

      expect(seen())->toEqual([
        ("TestAggregate", "ref-1", "accepted", "", 2),
        ("TestAggregate", "ref-2", "rejected/domain", "AlreadyExists", 0),
        ("TestAggregate", "ref-3", "accepted", "", 2),
      ])
    })
  })

  describe("state-change slice", () => {
    testPromise("observes an accepted command with no side-channel installed", async () => {
      record()
      let _ = await runSlice(
        "ref-1",
        DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
      )

      expect(seen())->toEqual([
        ("TestStateChangeSlice", DcbFixtures.testMeta.msgId, "accepted", "", 1),
      ])
    })

    testPromise("reports a decide rejection as domain, with the declared error code", async () => {
      let _ = await runSlice(
        "ref-seed",
        DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
      )
      record()
      let _ = await runSlice(
        "ref-1",
        DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Again"}),
      )

      expect(seen())->toEqual([
        (
          "TestStateChangeSlice",
          DcbFixtures.testMeta.msgId,
          "rejected/domain",
          "ItemAlreadyExists",
          0,
        ),
      ])
    })

    testPromise("reports exhausted append conflicts as infrastructure", async () => {
      record()
      // One more failure than the retry loop can absorb.
      dcbMock.failNextAppends := 4
      let _ = await runSlice(
        "ref-1",
        DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
      )

      expect(seen())->toEqual([
        ("TestStateChangeSlice", DcbFixtures.testMeta.msgId, "rejected/infrastructure", "Conflict", 0),
      ])
    })
  })

  describe("registration", () => {
    testPromise("with nothing registered nothing is observed and the command is unaffected", async () => {
      let results = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      expect(results)->toEqual([Ok("ref-1")])
      expect(AggregateFixtures.mock.getAll()->Array.length)->toBe(1)
      expect(observed.contents->Array.length)->toBe(0)
    })

    testPromise("clearCommandOutcome stops observation", async () => {
      record()
      CommandTopic_Helpers.clearCommandOutcome()
      let _ = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      expect(observed.contents->Array.length)->toBe(0)
    })

    testPromise("an out-of-tree extension can register it from onColdStart", async () => {
      // The hook needs no registration path of its own: it has the shape the cold-start
      // seam already reaches, so an extension picks it up alongside the other four.
      module Accountant: RuntimeExtension.Extension = {
        let moduleUrl = "file:///pkg/accountant.res.mjs"
        let onColdStart = (~runtimeKind as _, ~component as _, ~plugin as _, ~platform as _) =>
          record()
      }
      RuntimeExtension.use(module(Accountant: RuntimeExtension.Extension))
      RuntimeExtension.notifyColdStart(
        ~runtimeKind=ComponentType.Aggregate,
        ~component="AllAggregates",
        ~plugin=Some("Catalog"),
        ~platform=Some("Shop"),
      )

      let _ = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      expect(seen())->toEqual([("TestAggregate", "ref-1", "accepted", "", 1)])
    })

    testPromise("a throwing hook is swallowed and the command still succeeds", async () => {
      CommandTopic_Helpers.registerCommandOutcome(_ =>
        JsError.throwWithMessage("hook exploded")
      )
      let results = await runAgg("ref-1", AggregateFixtures.AggSpec.Create({name: "Widget"}))

      // The outcome the hook observes has already happened — an observer must not undo it.
      expect(results)->toEqual([Ok("ref-1")])
      expect(AggregateFixtures.mock.getAll()->Array.length)->toBe(1)
    })
  })
})
