// Runtime handler for the read-model → AppSync Events state-topic relay —
// compiled, type-checked ReScript (replaces the inline JS `handlerCode` string
// in StateTopic_AppSync.res). Runtime-pure and SDK-free for signing (node:crypto
// via AppSyncEventsSigner_Ops; see the parity test); it uses the rescript-aws-sdk
// util-dynamodb unmarshaller (also Pulumi-free).
//
// Triggered by DynamoDB streams (one shared Lambda; routing is per-record via
// STATE_TOPIC_MAP). For each changed row it derives the entity channel and a
// `{changeKind, id, sortKeyValue?, seq, state?}` descriptor and publishes it. 4xx
// failures are logged and skipped; 5xx / network failures are recorded and
// rethrown after the batch so the EventSourceMapping retries
// (bisectBatchOnFunctionError).
//
// The descriptor is one of three implementations of a shared wire format (the
// others: `LocalStateChangeDescriptor` in reventless-local, `StateTopicPublish.mjs`
// for Postgres read models). They share no code — this module stays Pulumi-free so
// a core import can't drag deploy-time code into the Lambda's import graph — so
// `StateChangeDescriptorParityTest` drives all three and asserts they agree.


let endpoint = NodeProcess.env->Dict.get("APPSYNC_ENDPOINT")->Option.getOr("")

// STATE_TOPIC_MAP: `{ <tableName>: <topicName> }`, injected at deploy time.
let topicMap: dict<string> =
  switch NodeProcess.env->Dict.get("STATE_TOPIC_MAP")->Option.getOr("{}")->JSON.parseOrThrow->JSON.Decode.object {
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
  // Monotonic within the entity's shard lineage — records for one partition key
  // always land on the same shard — so it orders an entity's changes without
  // anything being written to the table. Sparse, so it detects staleness, not gaps.
  @as("SequenceNumber") sequenceNumber?: string,
}
type record = {
  eventID: string,
  eventName: string, // "INSERT" | "MODIFY" | "REMOVE"
  eventSourceARN: string,
  dynamodb?: streamRecord,
}
type event = {@as("Records") records: array<record>}

// ── Per-record derivations (ports of the former inline JS helpers) ───────────

// STATE_RETIRED_MAP: `{ <tableName>: {field, values?} }`, injected at deploy time
// beside STATE_TOPIC_MAP. This handler runs with no plugin registry in process —
// there is nothing here that could read a state schema — so the whole predicate
// has to arrive the same way the topic routing does. A table absent from the map
// declares no retirement, which is every table until one does.
//
// `values` absent is the boolean form. Carried as an object rather than as an
// encoded string because a `field=Value` convention is a parser this side and a
// writer the other, and the two drift the first time a state name contains the
// separator — an argument that only gets stronger now that a lifecycle can name
// several states.
let retiredMap: dict<Reventless.OwnerScope.retiredScope> =
  switch NodeProcess.env
  ->Dict.get("STATE_RETIRED_MAP")
  ->Option.getOr("{}")
  ->JSON.parseOrThrow
  ->JSON.Decode.object {
  | Some(d) =>
    let out = Dict.make()
    d->Dict.forEachWithKey((v, k) =>
      v
      ->JSON.Decode.object
      ->Option.flatMap(o =>
        o
        ->Dict.get("field")
        ->Option.flatMap(JSON.Decode.string)
        ->Option.map(field => {
          Reventless.OwnerScope.field,
          values: o
          ->Dict.get("values")
          ->Option.flatMap(JSON.Decode.array)
          ->Option.map(vs => vs->Array.filterMap(JSON.Decode.string)),
        })
      )
      ->Option.forEach(scope => out->Dict.set(k, scope))
    )
    out
  | None => Dict.make()
  }

let tableNameFromEventSourceArn = (arn: string): option<string> => {
  let parts = arn->String.split("/")
  switch (parts->Array.get(0), parts->Array.get(1), parts->Array.get(2)) {
  | (Some(prefix), Some(tableName), Some("stream")) if prefix->String.endsWith(":table") =>
    Some(tableName)
  | _ => None
  }
}

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

/** Cap on the serialised state payload, in characters. Must match
    `LocalStateChangeDescriptor.maxStateChars` and `StateTopicPublish.mjs`'s
    MAX_STATE_CHARS — see the local module for the reasoning. */
let maxStateChars = 60 * 1024

/** Build the change descriptor. Split out of `processRecord` so the wire format
    can be asserted against the other two implementations without a network call.

    `image` is the unmarshalled NewImage for a save, the OldImage for a REMOVE.
    A REMOVE carries neither `state` (there is no new row) nor `sortKeyValue`
    (a sort position for a deleted row has no consumer, and the other two
    implementations cannot produce one). */
let makeDescriptor = (
  ~changeKind: string,
  ~entityKey: string,
  ~image: dict<JSON.t>,
  ~seq: option<string>,
  ~retiredField: option<string>=?,
  ~retiredValues: option<array<string>>=?,
): JSON.t => {
  let removed = changeKind == "Removed"
  // A retired row publishes as metadata only, for the reason the other two
  // implementations do it: this channel reaches every subscriber of the view,
  // and a payload would deliver the row to the callers the resolvers refuse it
  // to. `Updated` with no state is the shape an oversized row already takes.
  // Both forms are the one question `isRetiredValue` answers, so nothing here
  // branches on which the view declared.
  let retired = switch retiredField {
  | Some(field) =>
    !removed &&
    {Reventless.OwnerScope.field, values: retiredValues}->Reventless.OwnerScope.isRetiredValue(
      image->Dict.get(field),
    )
  | None => false
  }
  let descriptor = Dict.make()
  descriptor->Dict.set("changeKind", JSON.Encode.string(changeKind))
  descriptor->Dict.set("id", JSON.Encode.string(entityKey))
  if !removed && !retired {
    pickSortKeyValue(image)->Option.forEach(v =>
      descriptor->Dict.set("sortKeyValue", JSON.Encode.string(v))
    )
  }
  seq->Option.forEach(s => descriptor->Dict.set("seq", JSON.Encode.string(s)))
  if !removed && !retired {
    let state = image->JSON.Encode.object
    let encoded = state->JSON.stringify
    if encoded->String.length <= maxStateChars {
      descriptor->Dict.set("state", state)
    } else {
      // Metadata-only still tells the client to refetch; a publish rejected for
      // size would tell it nothing at all.
      Console.warn(
        `STATE_PAYLOAD_DOWNGRADED id=${entityKey} chars=${encoded
          ->String.length
          ->Int.toString}`,
      )
    }
  }
  descriptor->JSON.Encode.object
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
        let descriptor = makeDescriptor(
          ~changeKind=changeKindFor(record.eventName),
          ~entityKey,
          ~image=unmarshalled,
          ~seq=dynamodb.sequenceNumber,
          ~retiredField=?tableNameFromEventSourceArn(record.eventSourceARN)
          ->Option.flatMap(t => retiredMap->Dict.get(t))
          ->Option.map(scope => scope.Reventless.OwnerScope.field),
          ~retiredValues=?tableNameFromEventSourceArn(record.eventSourceARN)
          ->Option.flatMap(t => retiredMap->Dict.get(t))
          ->Option.flatMap(scope => scope.Reventless.OwnerScope.values),
        )
        let body =
          Dict.fromArray([
            ("id", JSON.Encode.string(record.eventID)),
            ("channel", JSON.Encode.string(channel)),
            ("events", JSON.Encode.array([JSON.Encode.string(descriptor->JSON.stringify)])),
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
