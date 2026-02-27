S.enableJson()

// ─────────────────────────────────────────────────────────────
// Test event spec
// ─────────────────────────────────────────────────────────────

module ItemEventLogSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestItemEventLog"

  @schema
  type event = | ItemCreated({name: string}) | ItemDeleted({id: string})
}

// ─────────────────────────────────────────────────────────────
// Mock storage
// ─────────────────────────────────────────────────────────────

let storedEvents: ref<dict<array<JSON.t>>> = ref(Dict.make())
let failNextAppend = ref(false)
// Inject N transient failures: each call decrements the counter and returns ThrottlingException
let failNextAppendsWithTransient: ref<int> = ref(0)
// Total number of storage.append calls (including retried attempts)
let appendCallCount: ref<int> = ref(0)

let mockStorage: EventLog_Adapter.operations = {
  append: async (_seqNr, id, jsons) => {
    appendCallCount := appendCallCount.contents + 1
    if failNextAppend.contents {
      failNextAppend := false
      Error("mock storage failure")
    } else if failNextAppendsWithTransient.contents > 0 {
      failNextAppendsWithTransient := failNextAppendsWithTransient.contents - 1
      Error("ThrottlingException: Rate exceeded")
    } else {
      let existing = storedEvents.contents->Dict.get(id)->Option.getOr([])
      storedEvents.contents->Dict.set(id, existing->Array.concat(jsons))
      Ok()
    }
  },
  replay: async id => {
    storedEvents.contents->Dict.get(id)->Option.getOr([])
  },
}

// ─────────────────────────────────────────────────────────────
// Mock EventTopic module (stub make — never called in unit tests)
// ─────────────────────────────────────────────────────────────

let capturedPublishes: ref<array<Message.event'<string, ItemEventLogSpec.event>>> = ref([])

module MockEventTopic: EventTopic.T
  with module Spec.Id = ItemEventLogSpec.Id
  and type Spec.event = ItemEventLogSpec.event = {
  module Spec = {
    module Id = ItemEventLogSpec.Id
    @schema
    type event = ItemEventLogSpec.event
  }
  type publish = EventTopic.publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: EventTopic.publishJson}
  type component = Component.t<EventTopic.t, EventTopic.outputs, operations>
  let make = (~name as _, ~storageResources as _, ~opts as _=?): component => Obj.magic(0)
}

let mockEventTopicOps: MockEventTopic.operations = {
  publish: async events => {
    capturedPublishes := capturedPublishes.contents->Array.concat(events)
  },
  publishJson: async (_service, _meta, _json) => (),
}

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let makeEvent' = (id, event) => {
  Reventless.Message.id,
  meta: testMeta,
  event,
}

let reset = () => {
  storedEvents := Dict.make()
  failNextAppend := false
  failNextAppendsWithTransient := 0
  appendCallCount := 0
  capturedPublishes := []
}
