open AsyncTest
open AsyncTest.Expect
open CommandGeneratorFixtures

let _ = beforeEach(() => reset())

describe("CommandGenerator_Callback.generateCommand:", () => {
  describe("zero-param command", () => {
    testPromise("publishJsons called with plain string commandJson", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let _msgId = await TestGenerator.generateCommand(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      // Zero-param command serializes as a plain JSON string
      expect(publishedCmd.commandJson)->toEqual(JSON.Encode.string("Create"))
    })

    testPromise("returns a Pending outcome with non-empty msgId", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let outcome = await TestGenerator.generateCommand(payload)->Effect.runPromise
      let msgId = switch outcome {
      | CommandTopic.Pending({msgId}) => msgId
      | _ => ""
      }
      expect(msgId->String.length > 0)->toBe(true)
    })

    testPromise("meta.service equals AggregateSpec.name", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let _outcome = await TestGenerator.generateCommand(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect(publishedCmd.meta.service)->toBe(CmdGenAggSpec.name)
    })

    testPromise("meta.msgId equals meta.correlationId", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let outcome = await TestGenerator.generateCommand(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      let msgId = switch outcome {
      | CommandTopic.Pending({msgId}) => msgId
      | _ => ""
      }
      expect((publishedCmd.meta.msgId, publishedCmd.meta.correlationId))->toEqual((msgId, msgId))
    })
  })

  describe("multi-param command", () => {
    testPromise("publishJsons called with object commandJson {TAG, param}", async () => {
      let payload =
        makeOneParamPayload(~id="agg-1", ~command="CreateWithName", ~paramName="name", ~paramValue="Widget")
      let _msgId = await TestGenerator.generateCommand(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      // Multi-param command serializes as {TAG: "CreateWithName", name: "Widget"}
      let cmdObj = publishedCmd.commandJson->JSON.Decode.object->Option.getOrThrow
      expect(cmdObj->Dict.get("TAG"))->toEqual(Some(JSON.Encode.string("CreateWithName")))
      expect(cmdObj->Dict.get("name"))->toEqual(Some(JSON.Encode.string("Widget")))
    })
  })

  describe("schema validation failure", () => {
    testPromise("invalid command name throws an error", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="NonExistentCommand")
      let threw = ref(false)
      switch await TestGenerator.generateCommand(payload)->Effect.runPromise {
      | _ => ()
      | exception _ => threw := true
      }
      expect(threw.contents)->toBe(true)
    })
  })

  describe("StateChangeSlice envelope id derivation", () => {
    testPromise("single @partitionTag: id derived from tagged field when args have no id", async () => {
      let payload = makeSlicePayload(
        ~command="CreateItem",
        ~args=Dict.fromArray([
          ("itemId", JSON.Encode.string("item-42")),
          ("name", JSON.Encode.string("Widget")),
        ]),
      )
      let outcome = await singleTagSliceGen(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect(publishedCmd.id)->toBe("item-42")
      // sanity: outcome is well-formed
      let msgId = switch outcome {
      | CommandTopic.Pending({msgId}) => msgId
      | _ => ""
      }
      expect(msgId->String.length > 0)->toBe(true)
    })

    testPromise("composite @compositePartitionTag: id is joined partition-key value", async () => {
      let payload = makeSlicePayload(
        ~command="DeployVersion",
        ~args=Dict.fromArray([
          ("environment", JSON.Encode.string("prod")),
          ("service", JSON.Encode.string("checkout")),
          ("version", JSON.Encode.string("1.2.3")),
        ]),
      )
      let _outcome = await compositeTagSliceGen(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      // Composite key joins position-0 value, then sep[0] = "-", then position-1 value
      expect(publishedCmd.id)->toBe("prod-checkout")
    })

    testPromise("explicit id in args wins over derivation (regression check)", async () => {
      let payload = makeSlicePayload(
        ~command="CreateItem",
        ~args=Dict.fromArray([
          ("id", JSON.Encode.string("explicit-id")),
          ("itemId", JSON.Encode.string("item-99")),
          ("name", JSON.Encode.string("Gadget")),
        ]),
      )
      let _outcome = await singleTagSliceGen(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect(publishedCmd.id)->toBe("explicit-id")
    })
  })

  describe("Aggregate envelope id (regression)", () => {
    testPromise("explicit id in args is preserved unchanged", async () => {
      let payload = makeZeroParamPayload(~id="agg-7", ~command="Create")
      let _outcome = await TestGenerator.generateCommand(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect(publishedCmd.id)->toBe("agg-7")
    })
  })
})
