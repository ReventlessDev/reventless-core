// Unit tests for EventCollectorChannel_InMemory.
// Verifies resource collection in make() and subscriber wiring in connect().

open AsyncTest
open AsyncTest.Expect

let _ = TestRunner.setup()

let testMeta: ReventlessSpec.Message.meta = {
  service: "test",
  time: "",
  ip: "",
  user: "test",
  msgId: "",
  correlationId: "",
}

describe("EventCollectorChannel_InMemory", () => {
  describe("make", () => {
    testPromise("collects all event topic resources as channel resources", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestPublisher = EventTopicPublisher_InMemory.Make(TestBus)
      module TestCollector = EventCollectorChannel_InMemory.Make(TestBus)
      let pubA = TestPublisher.make(~name="topicA", ~storageResources=[], ~opts={})
      let pubB = TestPublisher.make(~name="topicB", ~storageResources=[], ~opts={})
      let eventTopics = Dict.fromArray([
        ("topicA", {ReventlessSpec.EventTopic.resources: pubA.resources}),
        ("topicB", {ReventlessSpec.EventTopic.resources: pubB.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~opts={})
      // Each publisher returns 1 resource, so 2 total
      expect(ch.resources->Array.length)->toBe(2)
    })

    testPromise("empty eventTopics produces empty resources", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestCollector = EventCollectorChannel_InMemory.Make(TestBus)
      let ch = TestCollector.make(~name="collector", ~eventTopics=Dict.make(), ~opts={})
      expect(ch.resources->Array.length)->toBe(0)
    })
  })

  describe("connect", () => {
    testPromise("subscribes to event topic; published events reach handlerRef", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestPublisher = EventTopicPublisher_InMemory.Make(TestBus)
      module TestCollector = EventCollectorChannel_InMemory.Make(TestBus)
      let received: ref<int> = ref(0)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      handlerRef :=
        Some(
          async (_, _ctx) => {
            received := received.contents + 1
          },
        )
      let runtime: Reventless.Runtime.environment<RuntimeEnvironment_InMemory.parts> = {
        parts: {handlerRef: handlerRef},
        resources: [],
      }
      let pub = TestPublisher.make(~name="eventA", ~storageResources=[], ~opts={})
      let eventTopics = Dict.fromArray([
        ("eventA", {ReventlessSpec.EventTopic.resources: pub.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~opts={})
      let channelSpec: Reventless.EventCollector_Adapter.channelSpec<JSON.t, unit, unit> = {
        channel: ch,
        eventTopics,
        resources: [],
      }
      let _ = TestCollector.connect(
        ~name="collector",
        ~channelSpecs=[channelSpec],
        ~runtime,
        ~opts={},
      )
      // Output.apply is async (2 microtask ticks). Await the resource name so its
      // apply callback (Bus.subscribeToEvents) has run before we publish.
      let resource0 = pub.resources->Array.getUnsafe(0)
      let _ = await resource0.name->TestRunner.resolve
      let publishFn = await pub.publishJson->TestRunner.resolve
      await publishFn("svc", testMeta, JSON.Null)
      expect(received.contents)->toBe(1)
    })

    testPromise("multiple event topics all deliver to the same handlerRef", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestPublisher = EventTopicPublisher_InMemory.Make(TestBus)
      module TestCollector = EventCollectorChannel_InMemory.Make(TestBus)
      let received: ref<int> = ref(0)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      handlerRef :=
        Some(
          async (_, _) => {
            received := received.contents + 1
          },
        )
      let runtime: Reventless.Runtime.environment<RuntimeEnvironment_InMemory.parts> = {
        parts: {handlerRef: handlerRef},
        resources: [],
      }
      let pub1 = TestPublisher.make(~name="topicX", ~storageResources=[], ~opts={})
      let pub2 = TestPublisher.make(~name="topicY", ~storageResources=[], ~opts={})
      let eventTopics = Dict.fromArray([
        ("topicX", {ReventlessSpec.EventTopic.resources: pub1.resources}),
        ("topicY", {ReventlessSpec.EventTopic.resources: pub2.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~opts={})
      let channelSpec: Reventless.EventCollector_Adapter.channelSpec<JSON.t, unit, unit> = {
        channel: ch,
        eventTopics,
        resources: [],
      }
      let _ = TestCollector.connect(
        ~name="collector",
        ~channelSpecs=[channelSpec],
        ~runtime,
        ~opts={},
      )
      let pub1Fn = await pub1.publishJson->TestRunner.resolve
      let pub2Fn = await pub2.publishJson->TestRunner.resolve
      await pub1Fn("svc", testMeta, JSON.Null)
      await pub2Fn("svc", testMeta, JSON.Null)
      expect(received.contents)->toBe(2)
    })

    testPromise("unset handlerRef does not crash on event delivery", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestPublisher = EventTopicPublisher_InMemory.Make(TestBus)
      module TestCollector = EventCollectorChannel_InMemory.Make(TestBus)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      let runtime: Reventless.Runtime.environment<RuntimeEnvironment_InMemory.parts> = {
        parts: {handlerRef: handlerRef},
        resources: [],
      }
      let pub = TestPublisher.make(~name="noHandlerTopic", ~storageResources=[], ~opts={})
      let eventTopics = Dict.fromArray([
        ("noHandlerTopic", {ReventlessSpec.EventTopic.resources: pub.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~opts={})
      let channelSpec: Reventless.EventCollector_Adapter.channelSpec<JSON.t, unit, unit> = {
        channel: ch,
        eventTopics,
        resources: [],
      }
      let _ = TestCollector.connect(
        ~name="collector",
        ~channelSpecs=[channelSpec],
        ~runtime,
        ~opts={},
      )
      let publishFn = await pub.publishJson->TestRunner.resolve
      await publishFn("svc", testMeta, JSON.Null)
      expect(true)->toBe(true)
    })
  })
})
