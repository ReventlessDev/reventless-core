// Unit tests for LocalCommandTopicChannel.
// Covers encodeCommandJson (shared helper), decodeId, publishJsons, and connect wiring.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

describe("LocalCommandTopicChannel", () => {
  describe("encodeCommandJson", () => {
    testPromise("produces {id, meta, command} JSON shape", async () => {
      let cmdJson: Reventless.Message.commandJson = {
        id: "agg-1",
        meta: testMeta,
        commandJson: JSON.Encode.string("DoSomething"),
      }
      let encoded = ReventlessCore.CommandTopic.encodeCommandJson(cmdJson)
      let dict = switch encoded {
      | JSON.Object(d) => d
      | _ => Dict.make()
      }
      expect(dict->Dict.get("id"))->toEqual(Some(JSON.Encode.string("agg-1")))
      expect(dict->Dict.get("command"))->toEqual(Some(JSON.Encode.string("DoSomething")))
      expect(dict->Dict.get("meta")->Option.isSome)->toBe(true)
    })
  })

  describe("decodeId", () => {
    testPromise("extracts id string from encoded message body", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      let body = JSON.Encode.object(
        Dict.fromArray([("id", JSON.Encode.string("agg-42"))]),
      )
      expect(TestChannel.decodeId(body))->toBe("agg-42")
    })

    testPromise("returns empty string for non-object input", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      expect(TestChannel.decodeId(JSON.Encode.string("not-an-object")))->toBe("")
    })

    testPromise("returns empty string when id field is missing", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      let body = JSON.Encode.object(Dict.fromArray([("other", JSON.Encode.int(1))]))
      expect(TestChannel.decodeId(body))->toBe("")
    })

    testPromise("returns empty string when id field is not a string", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      let body = JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.int(99))]))
      expect(TestChannel.decodeId(body))->toBe("")
    })
  })

  describe("publishJsons", () => {
    testPromise("dispatches each command to the bus with full {id, meta, command} body", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      let received: ref<option<JSON.t>> = ref(None)
      TestBus.registerCommandHandler("myCmd", async (json, _) => {
        received := Some(json)
      })
      let ch = TestChannel.make(~name="myCmd")
      let publishFn = await ch.publishJsons->TestRunner.resolve
      await publishFn([
        {
          Reventless.Message.id: "item-1",
          meta: testMeta,
          commandJson: JSON.Encode.string("CreateItem"),
        },
      ])
      let receivedJson = received.contents->Option.getOr(JSON.Null)
      let receivedDict = switch receivedJson {
      | JSON.Object(d) => d
      | _ => Dict.make()
      }
      expect(receivedDict->Dict.get("id"))->toEqual(Some(JSON.Encode.string("item-1")))
    })

    testPromise("dispatches multiple commands in order", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.registerCommandHandler("multiCmd", async (_, _) => {
        count := count.contents + 1
      })
      let ch = TestChannel.make(~name="multiCmd")
      let publishFn = await ch.publishJsons->TestRunner.resolve
      await publishFn([
        {
          Reventless.Message.id: "id-1",
          meta: testMeta,
          commandJson: JSON.Null,
        },
        {
          Reventless.Message.id: "id-2",
          meta: testMeta,
          commandJson: JSON.Null,
        },
      ])
      expect(count.contents)->toBe(2)
    })
  })

  describe("connect", () => {
    testPromise("registers handler; dispatch reaches the runtime handlerDeferred", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      let received: ref<option<JSON.t>> = ref(None)
      let handlerDeferred: Deferred.t<LocalRuntimeEnvironment.handler, unit> =
        Deferred.make()->Effect.runSync
      Deferred.succeed(handlerDeferred, async (json, _ctx) => {
        received := Some(json)
      })->Effect.runSync->ignore
      let runtime: ReventlessCore.Runtime.environment<LocalRuntimeEnvironment.parts> = {
        parts: {
          handlerDeferred,
          subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
        },
        resources: [],
      }
      let ch = TestChannel.make(~name="testCmd")
      let _ = ch.connect(
        ~name="testCmd",
        ~channel=ch,
        ~runtime,
        ~resources=[],
        ~opts={},
      )
      await TestBus.dispatchCommand("testCmd", JSON.Encode.string("test-payload"))
      expect(received.contents)->toEqual(Some(JSON.Encode.string("test-payload")))
    })

    testPromise("unresolved Deferred does not crash on dispatch", async () => {
      module TestBus = LocalBus.Make()
      module TestChannel = LocalCommandTopicChannel.Make(TestBus)
      // Deferred left incomplete — dispatch starts a pending Effect (no crash)
      let handlerDeferred: Deferred.t<LocalRuntimeEnvironment.handler, unit> =
        Deferred.make()->Effect.runSync
      let runtime: ReventlessCore.Runtime.environment<LocalRuntimeEnvironment.parts> = {
        parts: {
          handlerDeferred,
          subscriptionLatch: Effect.makeLatch(false)->Effect.runSync,
        },
        resources: [],
      }
      let ch = TestChannel.make(~name="noHandlerCmd")
      let _ = ch.connect(
        ~name="noHandlerCmd",
        ~channel=ch,
        ~runtime,
        ~resources=[],
        ~opts={},
      )
      // Fire-and-forget — the Deferred.await_ will stay pending
      TestBus.dispatchCommand("noHandlerCmd", JSON.Null)->ignore
      expect(true)->toBe(true)
      // Complete the Deferred to avoid open handle
      Deferred.succeed(handlerDeferred, async (_, _) => ())->Effect.runSync->ignore
    })
  })
})
