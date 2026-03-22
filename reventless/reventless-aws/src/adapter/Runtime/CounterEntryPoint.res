// Compiled entry point for Counter Lambda handlers.
// Replaces CounterHandlerFactory.mjs + generated entry point code.
// Lives in the Lambda Layer; imported by a static one-line re-export in the code asset.
//
// At cold start:
//   1. Reads HANDLER_CONFIG from env vars
//   2. Dynamically imports user Target Spec and Mappings modules
//   3. Wires Counter_Callback.Make + EventMapper_Callback.MakeCounterHandler
//   4. Routes DynamoDB Stream events (references + counts tables)

// === Dynamic import ===
let dynamicImport: string => promise<'a> = %raw(`(specifier) => import('/var/task/node_modules/' + specifier)`)

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Config types ===

type handlerConfig = {
  targetSpecModule: string,
  mappingsModule: string,
  countsTableName: string,
  publishQueueUrl: string,
  referencesStreamArn: string,
  countsStreamArn: string,
}

type config = handlerConfig

// === Build-verified functor imports ===

@module(
  "@reventlessdev/reventless-core/src/components/Counter/Counter_Callback.res.mjs"
)
external counterCallbackMake: 'a => 'b = "Make"

@module(
  "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs"
)
external makeCounterHandler: 'a => 'b => 'c => 'd = "MakeCounterHandler"

@module(
  "@reventlessdev/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res.mjs"
)
external qdbCount: 'a => 'b = "count"

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

@module("@reventlessdev/reventless-aws/src/util/Util_DynamoDbStream_Runtime.res.mjs")
external parseDynamoDbStreamRecordState: 'a => 'b = "parseDynamoDbStreamRecordState"

@module("sury/src/S.res.mjs")
external surySchema: ('a => 'b) => 'c = "schema"

@module("sury/src/S.res.mjs")
external suryString: 'a = "string"

@module("sury/src/S.res.mjs")
external suryInt: 'a = "$$int"

@module("sury/src/S.res.mjs")
external parseJsonOrThrow: ('a, 'b) => 'c = "parseJsonOrThrow"

// === Helpers ===

@module("./HandlerFactoryHelpers.res.mjs")
external patchSpecId: 'a => 'b = "patchSpecId"

@module("./HandlerFactoryHelpers.res.mjs")
external makeTableRef: string => 'a = "makeTableRef"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

// === Object/field accessors ===

@get external getRecords: 'a => Nullable.t<array<'b>> = "Records"
@get external getEventSource: 'a => string = "eventSource"
@get external getEventSourceARN: 'a => string = "eventSourceARN"
@get external getTAG: 'a => int = "TAG"
@get external get_0: 'a => 'b = "_0"
@get external get_1: 'a => 'b = "_1"
@get external getHandleCounterEvents: 'a => 'b = "handleCounterEvents"
@get external getCounterHandler: 'a => 'b = "counterHandler"

let mkCallbackSpec: (string, 'a, 'b) => 'c = %raw(`
  (name, countsDbCount, jsonEventsHandler) => ({
    name,
    countsDbCount,
    jsonEventsHandler,
  })
`)

let mkCounterOps: ('a, 'b) => 'c = %raw(`
  (publishJsons, queryEngine) => ({
    publishJsons,
    queryEngine,
  })
`)

let mkNoopQueryEngine: unit => 'a = %raw(`() => ({
  query: async () => [],
  queryAll: async () => [],
})`)

// Build the referencesView schema: {id: string, inc: int}
let mkReferencesViewSchema: unit => 'a = %raw(`() => {
  const S = arguments.callee._S;
  return S.schema((s) => ({
    id: s.m(S.string),
    inc: s.m(S.$$int),
  }));
}`)

// Inline schema construction using sury
let buildReferencesViewSchema: unit => 'a = %raw(`
  function() {
    // Dynamic import would be complex; use the already-imported S module
    const schema = (function(s_schema, s_string, s_int) {
      return s_schema((s) => ({
        id: s.m(s_string),
        inc: s.m(s_int),
      }));
    })(surySchema, suryString, suryInt);
    return schema;
  }
`)

// Simpler approach: build schema at module level using the imported externals
let referencesViewSchema = surySchema(s => {
  let m: ('a, 'b) => 'c = %raw(`(s, schema) => s.m(schema)`)
  {"id": m(s, suryString), "inc": m(s, suryInt)}
})

let callCounterHandler: ('a, array<(string, int)>, array<'b>) => promise<unit> = %raw(`
  (fn, references, counts) => fn(references, counts)
`)

// === Initialization ===

type counterHandlerFn

let buildHandler = async (): counterHandlerFn => {
  let configStr = env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{}`)
  let config: config = configStr->JSON.parseOrThrow->Obj.magic

  let targetSpecModule = await dynamicImport(config.targetSpecModule)
  let mappingsModule = await dynamicImport(config.mappingsModule)

  let patchedTarget = patchSpecId(targetSpecModule)

  let countsTable = makeTableRef(config.countsTableName)
  let countsDbCount = qdbCount(countsTable)

  let pubJsons = sqsPublishJsons(makeQueueRef(config.publishQueueUrl), "SQS_FIFO")
  let queryEngine = mkNoopQueryEngine()

  let counterHandler = makeCounterHandler(patchedTarget)(mappingsModule)(
    mkCounterOps(pubJsons, queryEngine),
  )

  let callback = counterCallbackMake(
    mkCallbackSpec("BundledCounter", countsDbCount, counterHandler->getHandleCounterEvents),
  )

  Obj.magic((config.referencesStreamArn, config.countsStreamArn, callback))
}

let initPromise = buildHandler()

// === Exported handler ===

let handler = async (event, _context) => {
  let (referencesStreamArn, countsStreamArn, callback) = (await initPromise)->Obj.magic

  let records = event->getRecords->Nullable.toOption->Option.getOr([])

  let dynamoDbRecords = records->Array.filter(r =>
    r->getEventSource == "aws:dynamodb" &&
      (r->getEventSourceARN == referencesStreamArn ||
        r->getEventSourceARN == countsStreamArn)
  )

  let referenceRecords = dynamoDbRecords->Array.filter(r =>
    r->getEventSourceARN == referencesStreamArn
  )
  let countRecords = dynamoDbRecords->Array.filter(r =>
    r->getEventSourceARN == countsStreamArn
  )

  let references = referenceRecords->Array.filterMap(record => {
    let state = parseDynamoDbStreamRecordState(record)
    let tag = state->getTAG
    switch tag {
    | 0 => {
        // NewImage(id, newImage)
        let id: string = state->get_0->Obj.magic
        let newImage = state->get_1
        let inc = try {
          let parsed = parseJsonOrThrow(newImage, referencesViewSchema)
          (parsed->Obj.magic: {"inc": int})["inc"]
        } catch {
        | _ => 1
        }
        Some((id, inc))
      }
    | 2 => {
        Console.log(`CounterEntryPoint (references): ignoring duplicate id: ${(state->get_0->Obj.magic: string)}`)
        None
      }
    | _ => None
    }
  })

  let counts = countRecords->Array.filterMap(record => {
    let state = parseDynamoDbStreamRecordState(record)
    let tag = state->getTAG
    switch tag {
    | 0 => Some(state->get_1) // NewImage
    | 2 => Some(state->get_1) // NewAndOldImage
    | _ => None
    }
  })

  await callCounterHandler(callback->getCounterHandler, references, counts)
  ""
}
