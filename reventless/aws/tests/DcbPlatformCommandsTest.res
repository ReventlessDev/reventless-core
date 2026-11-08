// An automation or outbound translation on AWS hears a command's outcome by invoking
// its plugin's DCB command Lambda: the payload it sends, the outcomes it reads back,
// Route P that answers them, and the config that names the function.

open JestGlobals

@module("./DcbPlatformCommandsStub.mjs")
external answerPlatformCommands: JSON.t => promise<JSON.t> = "answerPlatformCommands"

let cmdJson = (msgId): Reventless.Message.commandJson => {
  id: "ord-1",
  meta: {
    service: "Ordering",
    time: "2026-11-08T00:00:00Z",
    msgId,
    correlationId: "corr-1",
  },
  commandJson: Dict.fromArray([("TAG", "ShipOrder"->JSON.Encode.string)])->JSON.Encode.object,
}

describe("CommandTopic_Helpers.commandOutcomeOfJson", () => {
  testSync("reads back every outcome commandOutcomeToJson writes", () => {
    let outcomes: array<ReventlessCore.CommandTopic_Helpers.commandOutcome> = [
      Accepted({msgId: "a", entityId: "e-1", eventCount: 2}),
      Accepted({msgId: "b", eventCount: 0}),
      Rejected({
        msgId: "c",
        errorCode: "OutOfStock",
        errorDetail: Some("sku"),
        cause: DomainRejection,
      }),
      Rejected({msgId: "d", errorCode: "Forbidden", errorDetail: None, cause: AccessRefusal}),
      Rejected({
        msgId: "e",
        errorCode: "Conflict",
        errorDetail: None,
        cause: InfrastructureFailure,
      }),
      Pending({msgId: "f"}),
    ]
    outcomes->Array.forEach(
      outcome =>
        expect(
          outcome
          ->ReventlessCore.CommandTopic_Helpers.commandOutcomeToJson
          ->ReventlessCore.CommandTopic_Helpers.commandOutcomeOfJson,
        )->toEqual(Some(outcome)),
    )
  })
})

describe("DcbPlatformCommands_Runtime", () => {
  testSync("the payload marks the route and carries each command whole", () => {
    let payload = DcbPlatformCommands_Runtime.payloadOf([cmdJson("m-1")])
    let fields = payload->JSON.Decode.object->Option.getOrThrow
    expect(fields->Dict.get("__platformCommands"))->toEqual(Some(JSON.Encode.bool(true)))
    let first =
      fields
      ->Dict.get("commands")
      ->Option.flatMap(JSON.Decode.array)
      ->Option.flatMap(a => a->Array.get(0))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.getOrThrow
    expect(first->Dict.get("id"))->toEqual(Some(JSON.Encode.string("ord-1")))
    expect(first->Dict.get("commandJson"))->toEqual(Some(cmdJson("m-1").commandJson))
    expect(
      first
      ->Dict.get("meta")
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(m => m->Dict.get("msgId")),
    )->toEqual(Some(JSON.Encode.string("m-1")))
  })

  testSync("an answer it cannot read counts as not yet answered", () => {
    let answer = JSON.Encode.array([
      ReventlessCore.CommandTopic_Helpers.commandOutcomeToJson(
        Rejected({
          msgId: "m-1",
          errorCode: "OutOfStock",
          errorDetail: None,
          cause: DomainRejection,
        }),
      ),
      JSON.Encode.string("garbled"),
    ])
    expect(
      DcbPlatformCommands_Runtime.outcomesOf(
        [cmdJson("m-1"), cmdJson("m-2"), cmdJson("m-3")],
        answer,
      ),
    )->toEqual(
      (
        [
          Rejected({
            msgId: "m-1",
            errorCode: "OutOfStock",
            errorDetail: None,
            cause: DomainRejection,
          }),
          Pending({msgId: "m-2"}),
          Pending({msgId: "m-3"}),
        ]: array<ReventlessCore.CommandTopic_Helpers.commandOutcome>
      ),
    )
  })

  testPromise("Route P answers one outcome per command, by its message id", async () => {
    let answer = await answerPlatformCommands(
      DcbPlatformCommands_Runtime.payloadOf([cmdJson("m-1"), cmdJson("m-2")])
      ->JSON.Decode.object
      ->Option.flatMap(p => p->Dict.get("commands"))
      ->Option.getOrThrow,
    )
    let outcomes = DcbPlatformCommands_Runtime.outcomesOf([cmdJson("m-1"), cmdJson("m-2")], answer)
    expect(
      outcomes->Array.map(
        o =>
          switch o {
          | Accepted({msgId}) | Rejected({msgId}) | Pending({msgId}) => msgId
          },
      ),
    )->toEqual(["m-1", "m-2"])
    // Answered inline, not left to the queue.
    expect(
      outcomes->Array.every(
        o =>
          switch o {
          | Pending(_) => false
          | _ => true
          },
      ),
    )->toBe(true)
  })
})

describe("AutomationSliceEntryPoint_Ops: the command function", () => {
  let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))
  let str = JSON.Encode.string
  let config = (~commandFunction=?) =>
    obj(
      [
        ("queueUrl", str("https://sqs/dcb")),
        ("urns", JSON.Encode.array([str("arn:stream")])),
        (
          "handlers",
          JSON.Encode.array([
            obj([("n", str("ToDcb")), ("q", str("t1"))]),
            obj([("n", str("ToAggregate")), ("q", str("t2")), ("k", str("https://sqs/agg"))]),
          ]),
        ),
      ]->Array.concat(commandFunction->Option.mapOr([], f => [("commandFunction", str(f))])),
    )->JSON.stringify

  testSync(
    "a slice sending to the DCB topic is given the function; one with its own queue is not",
    () => {
      let entries = AutomationSliceEntryPoint_Ops.parseHandlerConfigWithModules(
        "",
        config(~commandFunction="OrderingDcbCmdHandler-123"),
      )
      expect(entries->Array.map(e => e.commandFunction))->toEqual([
        Some("OrderingDcbCmdHandler-123"),
        None,
      ])
    },
  )

  testSync("without a function in the config, no slice waits", () => {
    let entries = AutomationSliceEntryPoint_Ops.parseHandlerConfigWithModules("", config())
    expect(entries->Array.map(e => e.commandFunction))->toEqual([None, None])
  })
})
