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
})
