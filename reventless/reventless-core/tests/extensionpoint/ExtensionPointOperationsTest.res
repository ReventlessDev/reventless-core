// Unit tests for ExtensionPoint_Operations.Make.
// Tests outgoingJsonEventsHandler which maps aggregate events to EP actions.

open AsyncTest
open AsyncTest.Expect

S.enableJson()

// ─────────────────────────────────────────────────────────────
// EP Spec — minimal types for operations tests
// ─────────────────────────────────────────────────────────────

module OpsEPSpec = {
  let name = "OpsTestEP"

  @schema
  type command = | OpsEPCmd({id: string})

  @schema
  type event = | OpsEPEvent({result: string})

  @schema
  type directive = | OpsEPNoDirective
}

// ─────────────────────────────────────────────────────────────
// Captured state (reset in beforeEach)
// ─────────────────────────────────────────────────────────────

let capturedPublished: ref<array<(string, Message.meta, JSON.t)>> = ref([])
let capturedCallCount: ref<int> = ref(0)

// ─────────────────────────────────────────────────────────────
// Mapping 1: returns AbstractPublishEvent (source agg = "PublishAgg")
// ─────────────────────────────────────────────────────────────

let outgoingMeta: Message.meta = {
  service: "PublishAgg",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "tester",
  msgId: "ops-msg-1",
  correlationId: "ops-corr-1",
}

module TestPublishMapping = {
  module ExtensionPoint = OpsEPSpec
  let aggregateName = "PublishAgg"

  let mapIncomingCommands = (
    _topicItems,
    _createSchedule: Reventless.Schedule.create,
    _deleteSchedule: Reventless.Schedule.delete,
    _queryEngine: Reventless.QueryEngine.operations,
  ) => []

  let mapOutgoingEvent = Some(
    (eventJson, _createSchedule, _deleteSchedule, _queryEngine) => {
      [
        Reventless.ExtensionPointMapping.AbstractPublishEvent("ep-dest", outgoingMeta, eventJson),
      ]
    },
  )
}

// ─────────────────────────────────────────────────────────────
// Mapping 2: returns AbstractCall (source agg = "CallAgg")
// ─────────────────────────────────────────────────────────────

module TestCallMapping = {
  module ExtensionPoint = OpsEPSpec
  let aggregateName = "CallAgg"

  let mapIncomingCommands = (
    _topicItems,
    _createSchedule: Reventless.Schedule.create,
    _deleteSchedule: Reventless.Schedule.delete,
    _queryEngine: Reventless.QueryEngine.operations,
  ) => []

  let mapOutgoingEvent = Some(
    (_eventJson, _createSchedule, _deleteSchedule, _queryEngine) => {
      [
        Reventless.ExtensionPointMapping.AbstractCall(async () => {
          capturedCallCount := capturedCallCount.contents + 1
        }),
      ]
    },
  )
}

// ─────────────────────────────────────────────────────────────
// Mapping 3: returns AbstractPublishEventAsync (source agg = "AsyncAgg")
// ─────────────────────────────────────────────────────────────

module TestAsyncMapping = {
  module ExtensionPoint = OpsEPSpec
  let aggregateName = "AsyncAgg"

  let mapIncomingCommands = (
    _topicItems,
    _createSchedule: Reventless.Schedule.create,
    _deleteSchedule: Reventless.Schedule.delete,
    _queryEngine: Reventless.QueryEngine.operations,
  ) => []

  let mapOutgoingEvent = Some(
    (eventJson, _createSchedule, _deleteSchedule, _queryEngine) => {
      let asyncResult: promise<(string, Message.meta, JSON.t)> = Promise.resolve((
        "ep-async-dest",
        outgoingMeta,
        eventJson,
      ))
      [Reventless.ExtensionPointMapping.AbstractPublishEventAsync(asyncResult)]
    },
  )
}

// ─────────────────────────────────────────────────────────────
// Mappings module — all three mappings combined
// ─────────────────────────────────────────────────────────────

module TestOpsMappings = {
  module Spec = OpsEPSpec
  module type Mapping = Reventless.ExtensionPointMapping.T with module ExtensionPoint := OpsEPSpec
  let mappings: array<module(Mapping)> = [
    module(TestPublishMapping),
    module(TestCallMapping),
    module(TestAsyncMapping),
  ]
}

// ─────────────────────────────────────────────────────────────
// Ops module — mocked infrastructure
// ─────────────────────────────────────────────────────────────

module TestOps = {
  let publishToEventTopic: EventTopic.publishJson = async (id, meta, eventJson) => {
    capturedPublished := capturedPublished.contents->Array.concat([(id, meta, eventJson)])
  }

  let commandTopicResources: array<Adapter.resolvedResource> = []

  let scheduler: Scheduler.operations = {
    createSchedule: async (_, _) => (),
    deleteSchedule: async (_, _) => (),
  }

  let queryEngine: Reventless.QueryEngine.operations = {
    scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
    query: async (
      ~readModelName as _,
      ~key as _=?,
      ~id as _,
      ~subIdConfig as _=?,
      ~filterConfigs as _=?,
      ~ascending as _=?,
      ~limit as _=?,
    ) => [],
  }

  let resourceNaming: Reventless.ResourceNaming.operations = {
    validateName: n => n,
    urnName: n => n,
  }
}

// ─────────────────────────────────────────────────────────────
// Unit under test
// ─────────────────────────────────────────────────────────────

module EpOps = ExtensionPoint_Operations.Make(OpsEPSpec, TestOpsMappings, TestOps)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let makeEventJsonForAgg = (aggregateName: string): JSON.t => {
  let meta: Message.meta = {
    service: aggregateName,
    time: "2024-01-01T00:00:00Z",
    ip: "127.0.0.1",
    user: "tester",
    msgId: "msg-test",
    correlationId: "corr-test",
  }
  JSON.Encode.object(
    Dict.fromArray([
      ("meta", meta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema)),
      ("event", JSON.Encode.string("SomeEvent")),
    ]),
  )
}

let reset = () => {
  capturedPublished := []
  capturedCallCount := 0
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("ExtensionPoint_Operations.Make:", () => {
  let _ = beforeEach(() => reset())

  describe("outgoingJsonEventsHandler — AbstractPublishEvent:", () => {
    testPromise("known aggregate calls publishToEventTopic with correct destination id", async () => {
      let eventJson = makeEventJsonForAgg("PublishAgg")
      await EpOps.outgoingJsonEventsHandler(eventJson, ())
      expect(capturedPublished.contents->Array.length)->toBe(1)
      let item = capturedPublished.contents->Array.getUnsafe(0)
      let (id, _, _) = item
      expect(id)->toBe("ep-dest")
    })

    testPromise("publishToEventTopic receives the original event JSON", async () => {
      let eventJson = makeEventJsonForAgg("PublishAgg")
      await EpOps.outgoingJsonEventsHandler(eventJson, ())
      let item = capturedPublished.contents->Array.getUnsafe(0)
      let (_, _, capturedEventJson) = item
      expect(capturedEventJson)->toEqual(eventJson)
    })
  })

  describe("outgoingJsonEventsHandler — AbstractCall:", () => {
    testPromise("known aggregate with AbstractCall invokes the handler", async () => {
      let eventJson = makeEventJsonForAgg("CallAgg")
      await EpOps.outgoingJsonEventsHandler(eventJson, ())
      expect(capturedCallCount.contents)->toBe(1)
      expect(capturedPublished.contents->Array.length)->toBe(0)
    })
  })

  describe("outgoingJsonEventsHandler — AbstractPublishEventAsync:", () => {
    testPromise("async mapping resolves and calls publishToEventTopic", async () => {
      let eventJson = makeEventJsonForAgg("AsyncAgg")
      await EpOps.outgoingJsonEventsHandler(eventJson, ())
      expect(capturedPublished.contents->Array.length)->toBe(1)
      let item = capturedPublished.contents->Array.getUnsafe(0)
      let (id, _, _) = item
      expect(id)->toBe("ep-async-dest")
    })
  })

  describe("outgoingJsonEventsHandler — no matching mapping:", () => {
    testPromise("event from unknown aggregate throws", async () => {
      let eventJson = makeEventJsonForAgg("UnknownAgg")
      let didThrow = ref(false)
      try {
        await EpOps.outgoingJsonEventsHandler(eventJson, ())
      } catch {
      | _ => didThrow := true
      }
      expect(didThrow.contents)->toBe(true)
    })
  })
})
