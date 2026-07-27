// Guards the typed cold-start core hoisted out of EventMapperEntryPoint.mjs:
//   - parseHandlerConfig — the {targetSpecModule, mappingsModule, queueUrl}
//     shape written by AggregateRuntime_Builder_Micro / _Micro_Async.
//   - makeCounterOps — the queryEngine stub shape (the former shell's stub had
//     `query`/`get` fields where QueryEngine.operations needs `scan`/`query`).
//   - makeStreamHandler — the full pipeline: SQS-record body parse →
//     commonEventsHandler → publish of the produced commands.

open JestGlobals

external toCbRecord: PulumiAws.SQS.Queue.record => PulumiAws.Lambda.CallbackFunction.record =
  "%identity"

let sqsRecord = (body: string): PulumiAws.Lambda.CallbackFunction.record =>
  (
    {
      messageId: "m1",
      receiptHandle: "r1",
      body,
      md5OfBody: "",
      eventSource: "aws:sqs",
      eventSourceARN: "arn:aws:sqs:eu-west-1:000000000000:q",
      awsRegion: "eu-west-1",
    }: PulumiAws.SQS.Queue.record
  )->toCbRecord

let context: PulumiAws.Lambda.context = {
  callbackWaitsForEmptyEventLoop: false,
  functionName: "test",
  functionVersion: "1",
  invokedFunctionArn: "arn:test",
  memoryLimitInMB: 128,
  awsRequestId: "req-1",
  logGroupName: "lg",
  logStreamName: "ls",
}

describe("EventMapperEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("reads the builder's field names", () => {
    let config = EventMapperEntryPoint_Ops.parseHandlerConfig(
      `{"targetSpecModule":"@x/p/src/Aggregate/Product.res.mjs","mappingsModule":"@x/p/src/Aggregate/Product_Mappings.res.mjs","queueUrl":"https://sqs/q"}`,
    )
    expect(config.targetSpecModule)->toEqual(Some("@x/p/src/Aggregate/Product.res.mjs"))
    expect(config.mappingsModule)->toEqual(Some("@x/p/src/Aggregate/Product_Mappings.res.mjs"))
    expect(config.queueUrl)->toEqual(Some("https://sqs/q"))
  })
})

describe("EventMapperEntryPoint_Ops.makeCounterOps", () => {
  test("queryEngine stubs return empty results instead of crashing", async () => {
    let ops = EventMapperEntryPoint_Ops.makeCounterOps({queueUrl: "https://sqs/q"})
    let scanned = await ops.queryEngine.scan(~readModelName="X", ~filterConfigs=[], ~limit=10)
    expect(scanned->Array.length)->toBe(0)
    let queried = await ops.queryEngine.query(
      ~readModelName="X",
      ~id=Reventless.QueryEngine.String("a"),
    )
    expect(queried->Array.length)->toBe(0)
  })
})

describe("EventMapperEntryPoint_Ops.makeStreamHandler", () => {
  test("parses SQS bodies, runs commonEventsHandler, publishes produced commands", async () => {
    let received: ref<array<JSON.t>> = ref([])
    let published: ref<array<ReventlessCore.Message.commandJson>> = ref([])
    let ops: EventMapperEntryPoint_Ops.counterOps = {
      publishJsons: async jsons => published := published.contents->Array.concat(jsons),
      queryEngine: {
        scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
        query: async (
          ~readModelName as _,
          ~key as _=?,
          ~id as _,
          ~subIdConfig as _=?,
          ~filterConfigs as _=?,
          ~ascending as _=?,
          ~limit as _=?,
        ) => [],
      },
    }
    let command: ReventlessCore.Message.commandJson = {
      id: "prd-1",
      meta: ReventlessCore.Message.generateMeta(~service="Product", ~ip="", ~user="test"),
      commandJson: JSON.Encode.string("Add"),
    }
    let commonEventsHandler: EventMapperEntryPoint_Ops.commonEventsHandler = async jsons => {
      received := received.contents->Array.concat(jsons)
      (Promise.resolve([command]), [])
    }

    let streamHandler = EventMapperEntryPoint_Ops.makeStreamHandler(ops, commonEventsHandler)
    let event: PulumiAws.Lambda.CallbackFunction.event = {
      records: [sqsRecord(`{"id":"e1","event":"Added"}`), sqsRecord("not json")],
    }
    await streamHandler(event, context)->Effect.runPromise

    // The unparsable body is dropped by the channel decode; the parsed one
    // reaches the mapper and its produced command is published.
    expect(received.contents->Array.length)->toBe(1)
    expect(published.contents->Array.length)->toBe(1)
    expect((published.contents->Array.getUnsafe(0)).id)->toBe("prd-1")
  })
})
