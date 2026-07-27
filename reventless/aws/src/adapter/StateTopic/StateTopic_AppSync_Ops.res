// Runtime handler for the read-model → AppSync Events state-topic relay —
// compiled, type-checked ReScript (replaces the inline JS `handlerCode` string
// in StateTopic_AppSync.res). Runtime-pure and SDK-free for signing (node:crypto
// via AppSyncEventsSigner_Ops; see the parity test); it uses the rescript-aws-sdk
// util-dynamodb unmarshaller (also Pulumi-free).
//
// Triggered by DynamoDB streams (one shared Lambda; routing is per-record via
// STATE_TOPIC_MAP). For each changed row it derives the entity channel and a
// `{changeKind, id, sortKeyValue?}` descriptor and publishes it. 4xx failures
// are logged and skipped; 5xx / network failures are recorded and rethrown after
// the batch so the EventSourceMapping retries (bisectBatchOnFunctionError).

@val @scope("process") external processEnv: dict<string> = "env"

let endpoint = processEnv->Dict.get("APPSYNC_ENDPOINT")->Option.getOr("")

// STATE_TOPIC_MAP: `{ <tableName>: <topicName> }`, injected at deploy time.
let topicMap: dict<string> =
  switch processEnv->Dict.get("STATE_TOPIC_MAP")->Option.getOr("{}")->JSON.parseOrThrow->JSON.Decode.object {
  | Some(obj) =>
    obj
    ->Dict.toArray
    ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
    ->Dict.fromArray
  | None => Dict.make()
  }

// ── DynamoDB stream event (only the fields this handler reads) ───────────────

type attributeValue = AwsSdk.DynamoDb.Util.attributeValue
type streamRecord = {
  @as("Keys") keys: dict<attributeValue>,
  @as("NewImage") newImage?: dict<attributeValue>,
  @as("OldImage") oldImage?: dict<attributeValue>,
}
type record = {
  eventID: string,
  eventName: string, // "INSERT" | "MODIFY" | "REMOVE"
  eventSourceARN: string,
  dynamodb?: streamRecord,
}
type event = {@as("Records") records: array<record>}

// ── Per-record derivations (ports of the former inline JS helpers) ───────────

// Map record.eventSourceARN → topicRoot via STATE_TOPIC_MAP. Stream ARNs look
// like arn:aws:dynamodb:<region>:<acct>:table/<TableName>/stream/<ts>; split on
// "/" gives [ "...:table", "<TableName>", "stream", "<ts>" ].
let topicRootFromEventSourceArn = (arn: string): option<string> => {
  let parts = arn->String.split("/")
  switch (parts->Array.get(0), parts->Array.get(1), parts->Array.get(2)) {
  | (Some(prefix), Some(tableName), Some("stream")) if prefix->String.endsWith(":table") =>
    topicMap->Dict.get(tableName)->Option.map(AppSyncEventsSigner_Ops.pathSegment)
  | _ => None
  }
}

// `String(value)` parity for scalar key attributes.
let jsonToString = (j: JSON.t): string =>
  switch j {
  | String(s) => s
  | Number(n) => n->Float.toString
  | Boolean(b) => b ? "true" : "false"
  | Null => "null"
  | _ => j->JSON.stringify
  }

// Build entityKey from the record's Keys. Framework convention: the partition
// key attribute is "id"; a composite table adds one sort-key attribute. Returns
// the ORIGINAL key string (channel-segmentised later via pathSegment).
let entityKeyFromRecord = (dynamodb: streamRecord): string => {
  let keys: dict<JSON.t> = AwsSdk.DynamoDb_Util_Helpers.unmarshallDict(dynamodb.keys)
  switch keys->Dict.get("id") {
  | None =>
    // Defensive: framework always names the partition key "id"; fall back to a
    // stable sort-join if a future table breaks the convention.
    keys
    ->Dict.keysToArray
    ->Array.toSorted(String.compare)
    ->Array.map(n => keys->Dict.get(n)->Option.mapOr("", jsonToString))
    ->Array.join("-")
  | Some(id) =>
    switch keys->Dict.keysToArray->Array.find(k => k != "id") {
    | None => id->jsonToString
    | Some(subIdName) =>
      id->jsonToString ++ "-" ++ keys->Dict.get(subIdName)->Option.mapOr("", jsonToString)
    }
  }
}

// Map DDB stream eventName → descriptor changeKind.
let changeKindFor = (eventName: string): string =>
  switch eventName {
  | "INSERT" => "Added"
  | "MODIFY" => "Updated"
  | "REMOVE" => "Removed"
  | _ => "Updated" // defensive default — shouldn't fire
  }

// Prefer updatedAt, then createdAt; None if neither is a string.
let pickSortKeyValue = (image: dict<JSON.t>): option<string> =>
  switch image->Dict.get("updatedAt")->Option.flatMap(JSON.Decode.string) {
  | Some(v) => Some(v)
  | None => image->Dict.get("createdAt")->Option.flatMap(JSON.Decode.string)
  }

// Publish one record; returns Some(errorMessage) on a transient (5xx / network)
// failure so the caller can rethrow after the batch, None otherwise.
let processRecord = async (
  ~record: record,
  ~region: string,
  ~creds: AppSyncEventsSigner_Ops.creds,
): option<string> =>
  switch topicRootFromEventSourceArn(record.eventSourceARN) {
  | None =>
    Console.warn2("StateTopic: unknown table for ARN", record.eventSourceARN)
    None
  | Some(topicRoot) =>
    switch record.dynamodb {
    | None => None
    | Some(dynamodb) =>
      let image = if record.eventName == "REMOVE" {
        dynamodb.oldImage
      } else {
        dynamodb.newImage
      }
      switch image {
      | None => None
      | Some(image) =>
        let entityKey = entityKeyFromRecord(dynamodb)
        let channel = `/default/${topicRoot}/${AppSyncEventsSigner_Ops.pathSegment(entityKey)}`
        let unmarshalled: dict<JSON.t> = AwsSdk.DynamoDb_Util_Helpers.unmarshallDict(image)
        let descriptor = Dict.make()
        descriptor->Dict.set("changeKind", JSON.Encode.string(changeKindFor(record.eventName)))
        descriptor->Dict.set("id", JSON.Encode.string(entityKey))
        pickSortKeyValue(unmarshalled)->Option.forEach(v =>
          descriptor->Dict.set("sortKeyValue", JSON.Encode.string(v))
        )
        let body =
          Dict.fromArray([
            ("id", JSON.Encode.string(record.eventID)),
            ("channel", JSON.Encode.string(channel)),
            (
              "events",
              JSON.Encode.array([JSON.Encode.string(descriptor->JSON.Encode.object->JSON.stringify)]),
            ),
          ])
          ->JSON.Encode.object
          ->JSON.stringify
        try {
          let res = await AppSyncEventsSigner_Ops.postEvent(
            ~endpoint,
            ~region,
            ~isoNow=Date.make()->Date.toISOString,
            ~creds,
            ~body,
          )
          if res->AppSyncEventsSigner_Ops.responseOk {
            None
          } else {
            let status = res->AppSyncEventsSigner_Ops.responseStatus
            let txt = await res->AppSyncEventsSigner_Ops.responseText
            let isTransient = status >= 500
            let tag = isTransient ? "transient" : "permanent"
            // 4xx: permanent (bad request, auth, channel format) — retrying won't
            // help. 5xx: transient — recorded and rethrown so the ESM retries.
            // Structured so a CloudWatch metric filter can surface each type.
            Console.error(
              `STATE_TOPIC_PUBLISH_FAILED type=${tag} status=${status->Int.toString} channel=${channel} body=${txt->String.slice(
                  ~start=0,
                  ~end=500,
                )}`,
            )
            isTransient ? Some(`StateTopic publish failed: ${status->Int.toString}`) : None
          }
        } catch {
        | exn =>
          // Network-level error (DNS, connection refused, timeout) — always transient.
          let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("")
          Console.error(
            `STATE_TOPIC_PUBLISH_FAILED type=transient status=network channel=${channel} err=${msg}`,
          )
          Some(msg == "" ? "StateTopic network error" : msg)
        }
      }
    }
  }

let handler = async (event: event): unit => {
  let region = AppSyncEventsSigner_Ops.region()
  let creds = AppSyncEventsSigner_Ops.envCreds()
  let transientErr = ref(None)
  // Sequential, mirroring the former for-await loop.
  await event.records->Array.reduce(Promise.resolve(), (acc, record) =>
    acc->Promise.then(async _ =>
      switch await processRecord(~record, ~region, ~creds) {
      | Some(msg) => transientErr := Some(msg)
      | None => ()
      }
    )
  )
  // Throw after the loop so one transient failure doesn't stop the other records'
  // descriptors from being emitted first; the ESM retries the batch.
  switch transientErr.contents {
  | Some(msg) => JsError.throwWithMessage(msg)
  | None => ()
  }
}
