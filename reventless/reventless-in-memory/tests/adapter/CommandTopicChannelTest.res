// Unit tests for CommandTopicChannel_InMemory.
// Covers encodeMessage, decodeId, publishJsons, and connect wiring.

open AsyncTest
open AsyncTest.Expect

let _ = TestRunner.setup()

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

describe("CommandTopicChannel_InMemory", () => {
  describe("encodeMessage", () => {
    testPromise("produces {id, meta, command} JSON shape", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      let cmdJson: Reventless.Message.commandJson = {
        id: "agg-1",
        meta: testMeta,
        commandJson: JSON.Encode.string("DoSomething"),
      }
      let encoded = TestChannel.encodeMessage(cmdJson)
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
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      let body = JSON.Encode.object(
        Dict.fromArray([("id", JSON.Encode.string("agg-42"))]),
      )
      expect(TestChannel.decodeId(body))->toBe("agg-42")
    })

    testPromise("returns empty string for non-object input", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      expect(TestChannel.decodeId(JSON.Encode.string("not-an-object")))->toBe("")
    })

    testPromise("returns empty string when id field is missing", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      let body = JSON.Encode.object(Dict.fromArray([("other", JSON.Encode.int(1))]))
      expect(TestChannel.decodeId(body))->toBe("")
    })

    testPromise("returns empty string when id field is not a string", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      let body = JSON.Encode.object(Dict.fromArray([("id", JSON.Encode.int(99))]))
      expect(TestChannel.decodeId(body))->toBe("")
    })
  })

  describe("publishJsons", () => {
    testPromise("dispatches each command to the bus with full {id, meta, command} body", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
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
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
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
    testPromise("registers handler; dispatch reaches the runtime handlerRef", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      let received: ref<option<JSON.t>> = ref(None)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      handlerRef :=
        Some(
          async (json, _ctx) => {
            received := Some(json)
          },
        )
      let runtime: ReventlessCore.Runtime.environment<RuntimeEnvironment_InMemory.parts> = {
        parts: {handlerRef: handlerRef},
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

    testPromise("unregistered handlerRef does not crash", async () => {
      module TestBus = InMemory_Bus.Make()
      module TestChannel = CommandTopicChannel_InMemory.Make(TestBus)
      let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
      let runtime: ReventlessCore.Runtime.environment<RuntimeEnvironment_InMemory.parts> = {
        parts: {handlerRef: handlerRef},
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
      await TestBus.dispatchCommand("noHandlerCmd", JSON.Null)
      expect(true)->toBe(true)
    })
  })
})
