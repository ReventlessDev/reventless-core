// Unit tests for LocalEventTopicPublisher.
// Verifies that make returns a correctly-named resource and that publishJson
// routes events to the correct bus topic subscribers.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "",
  ip: "",
  user: "test",
  msgId: "",
  correlationId: "",
}

describe("LocalEventTopicPublisher", () => {
  describe("make", () => {
    testPromise("returns one resource whose name resolves to the topic name", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      let pub = TestPublisher.make(~name="MyTopic", ~storageResources=[], ~opts={})
      expect(pub.resources->Array.length)->toBe(1)
      let resource = pub.resources->Array.getUnsafe(0)
      let name = await resource.name->TestRunner.resolve
      expect(name)->toBe("MyTopic")
    })
  })

  describe("publishJson", () => {
    testPromise("delivers event to subscriber on the same topic", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      let received: ref<option<JSON.t>> = ref(None)
      TestBus.subscribeToEvents("TestTopic", async (_, _, json) => {
        received := Some(json)
      })
      let pub = TestPublisher.make(~name="TestTopic", ~storageResources=[], ~opts={})
      let publishFn = await pub.publishJson->TestRunner.resolve
      await publishFn("svc", testMeta, JSON.Encode.string("hello"))
      expect(received.contents)->toEqual(Some(JSON.Encode.string("hello")))
    })

    testPromise("publishing to topic-a does not trigger topic-b subscriber", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      let countA: ref<int> = ref(0)
      let countB: ref<int> = ref(0)
      TestBus.subscribeToEvents("topic-a", async (_, _, _) => {
        countA := countA.contents + 1
      })
      TestBus.subscribeToEvents("topic-b", async (_, _, _) => {
        countB := countB.contents + 1
      })
      let pub = TestPublisher.make(~name="topic-a", ~storageResources=[], ~opts={})
      let publishFn = await pub.publishJson->TestRunner.resolve
      await publishFn("svc", testMeta, JSON.Null)
      expect(countA.contents)->toBe(1)
      expect(countB.contents)->toBe(0)
    })

    testPromise("passes service name from publishJson call to subscriber", async () => {
      module TestBus = LocalBus.Make()
      module TestPublisher = LocalEventTopicPublisher.Make(TestBus)
      let receivedService: ref<string> = ref("")
      TestBus.subscribeToEvents("svcTopic", async (service, _, _) => {
        receivedService := service
      })
      let pub = TestPublisher.make(~name="svcTopic", ~storageResources=[], ~opts={})
      let publishFn = await pub.publishJson->TestRunner.resolve
      await publishFn("MyService", testMeta, JSON.Null)
      expect(receivedService.contents)->toBe("MyService")
    })
  })
})
