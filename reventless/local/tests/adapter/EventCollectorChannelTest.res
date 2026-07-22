// Unit tests for LocalEventCollectorChannel.
// Verifies resource collection in make() and subscriber wiring in connect().

open JestGlobals

let _ = TestRunner.setup()

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "",
  ip: "",
  user: "test",
  msgId: "",
  correlationId: "",
}

// ─────────────────────────────────────────────────────────────
// Helper: build a minimal runtime with a completed handler Deferred
// ─────────────────────────────────────────────────────────────

let makeRuntime = (
  handler: LocalRuntimeEnvironment.handler,
): ReventlessCore.Runtime.environment<LocalRuntimeEnvironment.parts> => {
  let handlerDeferred: Deferred.t<LocalRuntimeEnvironment.handler, unit> =
    Deferred.make()->Effect.runSync
  Deferred.succeed(handlerDeferred, handler)->Effect.runSync->ignore
  {
    parts: {
      handlerDeferred,
      subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
    },
    resources: [],
  }
}

describe("LocalEventCollectorChannel", () => {
  describe("make", () => {
    testPromise("collects all event topic resources as channel resources", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      module TestCollector = LocalEventCollectorChannel.Make(TestBus)
      let pubA = TestPublisher.make(~name="topicA", ~storageResources=[], ~owner=None, ~opts={})
      let pubB = TestPublisher.make(~name="topicB", ~storageResources=[], ~owner=None, ~opts={})
      let eventTopics = Dict.fromArray([
        ("topicA", {ReventlessInfra.EventTopic.resources: pubA.resources}),
        ("topicB", {ReventlessInfra.EventTopic.resources: pubB.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~owner=None, ~opts={})
      // Each publisher returns 1 resource, so 2 total
      expect(ch.resources->Array.length)->toBe(2)
    })

    testPromise("empty eventTopics produces empty resources", async () => {
      module TestBus = LocalBus.Make()
      module TestCollector = LocalEventCollectorChannel.Make(TestBus)
      let ch = TestCollector.make(~name="collector", ~eventTopics=Dict.make(), ~owner=None, ~opts={})
      expect(ch.resources->Array.length)->toBe(0)
    })
  })

  describe("connect", () => {
    testPromise("subscribes to event topic; published events reach the handler", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      module TestCollector = LocalEventCollectorChannel.Make(TestBus)
      let received: ref<int> = ref(0)
      let runtime = makeRuntime(async (_, _ctx) => {
        received := received.contents + 1
      })
      let pub = TestPublisher.make(~name="eventA", ~storageResources=[], ~owner=None, ~opts={})
      let eventTopics = Dict.fromArray([
        ("eventA", {ReventlessInfra.EventTopic.resources: pub.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~owner=None, ~opts={})
      let channelSpec: ReventlessCore.EventCollector_Adapter.channelSpec<JSON.t, unit, unit> = {
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
      // Await the subscriptionLatch — opens after Output.apply fires and subscription registers
      await runtime.parts.subscriptionLatch->Latch.await_->Effect.runPromise
      let publishFn = await pub.publishJson->TestRunner.resolve
      await publishFn("svc", testMeta, JSON.Null)
      expect(received.contents)->toBe(1)
    })

    testPromise("multiple event topics all deliver to the same handler", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      module TestCollector = LocalEventCollectorChannel.Make(TestBus)
      let received: ref<int> = ref(0)
      let runtime = makeRuntime(async (_, _) => {
        received := received.contents + 1
      })
      let pub1 = TestPublisher.make(~name="topicX", ~storageResources=[], ~owner=None, ~opts={})
      let pub2 = TestPublisher.make(~name="topicY", ~storageResources=[], ~owner=None, ~opts={})
      let eventTopics = Dict.fromArray([
        ("topicX", {ReventlessInfra.EventTopic.resources: pub1.resources}),
        ("topicY", {ReventlessInfra.EventTopic.resources: pub2.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~owner=None, ~opts={})
      let channelSpec: ReventlessCore.EventCollector_Adapter.channelSpec<JSON.t, unit, unit> = {
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
      // Wait for both subscriptions via the publish functions (each Output resolves per-topic)
      let pub1Fn = await pub1.publishJson->TestRunner.resolve
      let pub2Fn = await pub2.publishJson->TestRunner.resolve
      await pub1Fn("svc", testMeta, JSON.Null)
      await pub2Fn("svc", testMeta, JSON.Null)
      expect(received.contents)->toBe(2)
    })

    testPromise("unresolved Deferred does not crash on event delivery", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      module TestCollector = LocalEventCollectorChannel.Make(TestBus)
      // Deferred left incomplete — bus callback starts a pending Effect (no crash)
      let handlerDeferred: Deferred.t<LocalRuntimeEnvironment.handler, unit> =
        Deferred.make()->Effect.runSync
      let runtime: ReventlessCore.Runtime.environment<LocalRuntimeEnvironment.parts> = {
        parts: {
          handlerDeferred,
          subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
        },
        resources: [],
      }
      let pub = TestPublisher.make(~name="noHandlerTopic", ~storageResources=[], ~owner=None, ~opts={})
      let eventTopics = Dict.fromArray([
        ("noHandlerTopic", {ReventlessInfra.EventTopic.resources: pub.resources}),
      ])
      let ch = TestCollector.make(~name="collector", ~eventTopics, ~owner=None, ~opts={})
      let channelSpec: ReventlessCore.EventCollector_Adapter.channelSpec<JSON.t, unit, unit> = {
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
      await runtime.parts.subscriptionLatch->Latch.await_->Effect.runPromise
      let publishFn = await pub.publishJson->TestRunner.resolve
      // Fire-and-forget — the Deferred.await_ will stay pending
      publishFn("svc", testMeta, JSON.Null)->ignore
      expect(true)->toBe(true)
      // Complete the Deferred to avoid open handle
      Deferred.succeed(handlerDeferred, async (_, _) => ())->Effect.runSync->ignore
    })
  })
})
