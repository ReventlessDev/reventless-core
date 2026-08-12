open JestGlobals
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

  // A transport hands over exactly what the caller supplied, and GraphQL lets a
  // caller supply null for any nullable argument. sury compiles an optional
  // field to `T | undefined`, so an explicit null used to fail to decode where
  // leaving the argument out succeeded — two ways of saying the same thing, one
  // of them accepted.
  describe("an argument sent as null", () => {
    let storeItem = (~args) => makeSlicePayload(~command="StoreItem", ~args)
    let data = JSON.Object(Dict.fromArray([("kind", JSON.String("blob"))]))
    let fieldOf = (cmd: Message.commandJson, name) =>
      cmd.commandJson->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))

    testPromise("is dropped, and the command decodes and publishes", async () => {
      let payload = storeItem(
        ~args=Dict.fromArray([
          ("itemId", JSON.Encode.string("item-1")),
          ("data", data),
          ("note", JSON.Null),
        ]),
      )
      let _outcome = await optionalFieldSliceGen(payload)->Effect.runPromise
      let publishedCmd = capturedCmds.contents->Array.getUnsafe(0)
      expect((capturedCmds.contents->Array.length, publishedCmd->fieldOf("note")))
      ->toEqual((1, None))
    })

    testPromise("carrying a value is left exactly as sent", async () => {
      let payload = storeItem(
        ~args=Dict.fromArray([
          ("itemId", JSON.Encode.string("item-2")),
          ("data", data),
          ("note", JSON.Encode.string("gift wrap")),
        ]),
      )
      let _outcome = await optionalFieldSliceGen(payload)->Effect.runPromise
      expect(capturedCmds.contents->Array.getUnsafe(0)->fieldOf("note"))
      ->toEqual(Some(JSON.Encode.string("gift wrap")))
    })

    // The control the drop is modelled on: absent and explicitly-null must
    // reach the domain as the same command.
    testPromise("and one simply omitted produce the same command", async () => {
      let withNull = storeItem(
        ~args=Dict.fromArray([
          ("itemId", JSON.Encode.string("item-3")),
          ("data", data),
          ("note", JSON.Null),
        ]),
      )
      let withoutKey = storeItem(
        ~args=Dict.fromArray([("itemId", JSON.Encode.string("item-3")), ("data", data)]),
      )
      let _ = await optionalFieldSliceGen(withNull)->Effect.runPromise
      let _ = await optionalFieldSliceGen(withoutKey)->Effect.runPromise
      let published = capturedCmds.contents
      expect((published->Array.getUnsafe(0)).commandJson)
      ->toEqual((published->Array.getUnsafe(1)).commandJson)
    })

    // Shallow on purpose. A null one level in is part of a value the caller
    // sent, not an argument they left out — `data` is opaque JSON and its own
    // nulls are data.
    testPromise("nested inside a value is left alone", async () => {
      let nested = JSON.Object(Dict.fromArray([("kind", JSON.Null)]))
      let payload = storeItem(
        ~args=Dict.fromArray([("itemId", JSON.Encode.string("item-4")), ("data", nested)]),
      )
      let _outcome = await optionalFieldSliceGen(payload)->Effect.runPromise
      expect(capturedCmds.contents->Array.getUnsafe(0)->fieldOf("data"))->toEqual(Some(nested))
    })
  })

  // A payload that does not decode describes the caller's own request, so a
  // transport is allowed to report it. Unmarked, it arrives as "Unexpected
  // error" and is indistinguishable from a database outage.
  describe("a payload that cannot be decoded", () => {
    let undecodable = () =>
      makeSlicePayload(
        ~command="StoreItem",
        ~args=Dict.fromArray([("itemId", JSON.Encode.string("item-9"))]),
      )

    testPromise("is refused rather than published", async () => {
      let refused = switch await optionalFieldSliceGen(undecodable())->Effect.runPromise {
      | _ => false
      | exception _ => true
      }
      expect((refused, capturedCmds.contents->Array.length))->toEqual((true, 0))
    })

    testPromise("is marked as the caller's fault, naming the field", async () => {
      let failure = switch await optionalFieldSliceGen(undecodable())->Effect.runPromise {
      | _ => None
      | exception e => Some(e)
      }
      let marked = failure->Option.mapOr(false, Plugin_ResolverError.isCallerFault)
      let saysWhy =
        failure
        ->Option.flatMap(JsExn.fromException)
        ->Option.flatMap(JsExn.message)
        ->Option.mapOr(false, m => m->String.includes("data"))
      expect((marked, saysWhy))->toEqual((true, true))
    })
  })
})
