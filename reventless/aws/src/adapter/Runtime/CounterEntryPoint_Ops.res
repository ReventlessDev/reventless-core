// Typed cold-start core for the Counter Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md):
// CounterEntryPoint.mjs keeps only the untyped seam — the dynamic `import()`
// of the target-spec/mappings modules named in HANDLER_CONFIG, the
// `patchSpecId` fix-up, and the EventMapper_Callback.MakeCounterHandler
// functor application consuming them. HANDLER_CONFIG parsing, the
// Counter_Callback.Make application (a functor over an inline module capturing
// runtime values), and the references/counts stream routing (the runtime twin
// of the deploy-time CounterHandler_DynamoDbStream_Runtime.handleStreamEvent,
// over plain ARN strings instead of Pulumi resources) live here, fully
// type-checked.
//
// Two shapes the former shell got wrong are repaired here:
// - It read `config.publishQueueUrl`, but the deploy side
//   (CounterHandler_DynamoDbStream.res) writes `publishChannelId` — the
//   CountFinished publish went to an undefined queue URL.
// - Its queryEngine stub had `query`/`queryAll` fields where
//   QueryEngine.operations needs `scan`/`query`.

type handlerConfig = {
  targetSpecModule?: string,
  mappingsModule?: string,
  countsTableName?: string,
  // The publish address of the target's command topic (SQS queue URL) — the
  // field name the deploy side actually writes.
  publishChannelId?: string,
  referencesStreamArn?: string,
  countsStreamArn?: string,
}
@val @scope("JSON") external jsonParse: string => handlerConfig = "parse"
// A real binding (not a bare external) so the shell can import it.
let parseHandlerConfig = (raw: string): handlerConfig => jsonParse(raw)

// ── Counter-handler operations (third argument of MakeCounterHandler) ───────
// The query engine is not available in the bundled handler; both operations
// silently return [] (the former shell's stub intent).

let makeCounterOps = (config: handlerConfig): EventMapperEntryPoint_Ops.counterOps => {
  let queueUrl = config.publishChannelId->Option.getOr("")
  let queue: Util_SQS_Runtime.resolvedQueue = {id: queueUrl, name: queueUrl, arn: ""}
  {
    publishJsons: queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO),
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
}

// ── Stream routing ──────────────────────────────────────────────────────────

// The references view rows carry the increment to apply: {id, inc}.
@schema
type referencesView = {
  id: string,
  inc: int,
}

// Pure routing: split a mixed stream batch into reference increments and
// count rows, keyed by the two source ARNs. Records from other sources are
// dropped silently (the former shell's behavior).
let splitRecords = (
  ~referencesStreamArn: string,
  ~countsStreamArn: string,
  records: array<PulumiAws.DynamoDb.Stream.record>,
): (array<(string, int)>, array<JSON.t>) => {
  let dynamoDbRecords =
    records->Array.filter(record =>
      record.eventSource == "aws:dynamodb" &&
        (record.eventSourceARN == referencesStreamArn ||
          record.eventSourceARN == countsStreamArn)
    )

  let (referenceRecords, countRecords) =
    dynamoDbRecords->Array.partition(record => record.eventSourceARN == referencesStreamArn)

  let references = referenceRecords->Array.filterMap(record =>
    switch record->Util_DynamoDbStream_Runtime.parseDynamoDbStreamRecordState {
    | NewImage(id, newImage) =>
      let inc = switch newImage->Reventless.Util_Sury.fromJson(referencesViewSchema) {
      | {inc} => inc
      | exception _ => 1
      }
      Some((id, inc))
    | NewAndOldImage(id, _, _) =>
      StreamRoutedEntryPoint_Ops.logDebug(
        "ignoring duplicate id: " ++ id,
        {comp: "CounterEntryPoint"},
      )
      None
    | _ => None
    }
  )

  let counts = countRecords->Array.filterMap(record =>
    switch record->Util_DynamoDbStream_Runtime.parseDynamoDbStreamRecordState {
    | NewImage(_, newImage) | NewAndOldImage(_, newImage, _) => Some(newImage)
    | _ => None
    }
  )

  (references, counts)
}

let makeHandler = (
  config: handlerConfig,
  jsonEventsHandler: ReventlessCore.Counter.jsonEventsHandler,
) => {
  module Callback = ReventlessCore.Counter_Callback.Make({
    let name = "BundledCounter"
    let countsDbCount = QueryDbStorage_DynamoDb_Runtime.count(
      (
        {
          id: config.countsTableName->Option.getOr(""),
          name: config.countsTableName->Option.getOr(""),
          arn: "",
          hashKey: "id",
        }: Util_DynamoDb_Runtime.resolvedTable
      ),
    )
    let jsonEventsHandler = jsonEventsHandler
  })

  let referencesStreamArn = config.referencesStreamArn->Option.getOr("")
  let countsStreamArn = config.countsStreamArn->Option.getOr("")

  async (event: PulumiAws.DynamoDb.Stream.event, _context: PulumiAws.Lambda.context) => {
    let (references, counts) = splitRecords(
      ~referencesStreamArn,
      ~countsStreamArn,
      event.records,
    )
    await Callback.counterHandler(~references, ~counts)
    ""
  }
}
