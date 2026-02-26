open AsyncTest
open AsyncTest.Expect
open CommandGeneratorFixtures

let _ = beforeEach(() => reset())

describe("CommandGenerator_Callback.generateCommand:", () => {
  describe("zero-param command", () => {
    testPromise("publishJsons called with plain string commandJson", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let _msgId = await TestGenerator.generateCommand(payload)
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      // Zero-param command serializes as a plain JSON string
      expect(publishedCmd.commandJson)->toEqual(JSON.Encode.string("Create"))
    })

    testPromise("returns a non-empty msgId string", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let msgId = await TestGenerator.generateCommand(payload)
      expect(msgId->String.length > 0)->toBe(true)
    })

    testPromise("meta.service equals AggregateSpec.name", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let _msgId = await TestGenerator.generateCommand(payload)
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect(publishedCmd.meta.service)->toBe(CmdGenAggSpec.name)
    })

    testPromise("meta.msgId equals meta.correlationId", async () => {
      let payload = makeZeroParamPayload(~id="agg-1", ~command="Create")
      let msgId = await TestGenerator.generateCommand(payload)
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect((publishedCmd.meta.msgId, publishedCmd.meta.correlationId))->toEqual((msgId, msgId))
    })
  })

  describe("multi-param command", () => {
    testPromise("publishJsons called with object commandJson {TAG, param}", async () => {
      let payload =
        makeOneParamPayload(~id="agg-1", ~command="CreateWithName", ~paramName="name", ~paramValue="Widget")
      let _msgId = await TestGenerator.generateCommand(payload)
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
      switch await TestGenerator.generateCommand(payload) {
      | _ => ()
      | exception _ => threw := true
      }
      expect(threw.contents)->toBe(true)
    })
  })
})
