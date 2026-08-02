// Runtime handler for the upload claim component — compiled, type-checked and
// Pulumi-free so it ships as an EntryPoint module (`Upload_Claim_S3` bundles it
// and attaches it to every ref-bearing event log's stream).
//
// It answers one question per committed event: has anything now referenced this
// uploaded object? If so the object stops being provisional, and the pending
// tag the mint side wrote comes off. An object nobody ever references keeps its
// tag, and a lifecycle rule — opt-in, and only once reconciliation has confirmed
// the tagged set is the unreferenced set — expires it.
//
// Triggered by DynamoDB streams over the event log tables, one shared Lambda for
// the whole platform: routing is per record via `CLAIM_REF_FIELDS`, keyed by the
// table name in `eventSourceARN`, exactly as `StateTopic_AppSync_Ops` routes its
// own shared Lambda. The event log row is `{event: "<Type>", data: {…}}`, so a
// row without an `event` attribute — a snapshot, a DCB fence row — is not an
// event and drops out before anything else runs.
//
// Four properties this needs, and one it deliberately does not:
//
//   Idempotent    untagging an untagged object, or one that is gone, is
//                 success. Replays and at-least-once delivery are non-events.
//   Scoped        it only ever touches keys under a declared store's served
//                 prefix; a ref pointing anywhere else is refused, not guessed.
//   Observable    lag is the one failure mode that deletes data, so the ESM's
//                 `IteratorAge` is alarmed at deploy time (see `Upload_Claim_S3`).
//   Narrow        its input is only event logs with a declared ref field. It is
//                 not a projection and must not grow into one.
//   Not ordered   the object exists before the event that references it — the
//                 PUT precedes the command — so there is no race to design for,
//                 and no consistent read is needed.
//
// Failure direction, deliberately: anything this handler cannot do leaves the
// tag on. A tag left behind delays nothing except an eventual expiry that is
// off by default; a tag wrongly removed is only ever a missed cleanup. The one
// unsafe direction — a claim that never runs while the rule is on — is what the
// lag alarm and the opt-in sequencing exist for.

module S3 = AwsSdk.S3

// ── Environment ─────────────────────────────────────────────────────────────

let getEnv = (k: string): option<string> =>
  switch NodeProcess.env->Dict.get(k) {
  | Some("") | None => None
  | Some(v) => Some(v)
  }

let parseEnvObject = (k: string): dict<JSON.t> =>
  switch getEnv(k)->Option.map(s => JSON.parseOrThrow(s)) {
  | Some(Object(obj)) => obj
  | _ => Dict.make()
  }

/** A store the claimer may untag in: its physical bucket and the prefix its keys
    are rooted at. Same `UPLOAD_STORES` shape the presign service reads, keyed by
    the qualified `{plugin}.{store}` name a declaration resolves to. */
type storeConfig = {
  bucket: string,
  prefix: string,
}

let decodeStore = (json: JSON.t): option<storeConfig> =>
  switch json {
  | Object(obj) =>
    switch (
      obj->Dict.get("bucket")->Option.flatMap(JSON.Decode.string),
      obj->Dict.get("prefix")->Option.flatMap(JSON.Decode.string),
    ) {
    | (Some(bucket), Some(prefix)) => Some({bucket, prefix})
    | _ => None
    }
  | _ => None
  }

let stores: dict<storeConfig> =
  parseEnvObject("UPLOAD_STORES")
  ->Dict.toArray
  ->Array.filterMap(((k, v)) => decodeStore(v)->Option.map(c => (k, c)))
  ->Dict.fromArray

/** One declared ref-bearing field, as `StorageRefFields.toJson` wrote it. */
type refField = {
  field: string,
  many: bool,
  store: string,
}

let decodeRefField = (json: JSON.t): option<refField> =>
  switch json {
  | Object(obj) =>
    switch (
      obj->Dict.get("field")->Option.flatMap(JSON.Decode.string),
      obj->Dict.get("store")->Option.flatMap(JSON.Decode.string),
    ) {
    | (Some(field), Some(store)) =>
      Some({
        field,
        many: obj->Dict.get("arity")->Option.flatMap(JSON.Decode.string) == Some("many"),
        store,
      })
    | _ => None
    }
  | _ => None
  }

let decodeEventFields = (json: JSON.t): dict<array<refField>> =>
  switch json {
  | Object(obj) =>
    obj
    ->Dict.toArray
    ->Array.map(((eventType, v)) => (
      eventType,
      switch v {
      | Array(items) => items->Array.filterMap(decodeRefField)
      | _ => []
      },
    ))
    ->Dict.fromArray
  | _ => Dict.make()
  }

/** `{ "<eventLogTableName>": { "<eventType>": [refField] } }`, baked at deploy
    time from the plugins' `@storageRef` declarations. Its keys are the whole of
    this component's input: a table absent from the map is a table it never
    reads a record from. */
let refFieldsByTable: dict<dict<array<refField>>> =
  parseEnvObject("CLAIM_REF_FIELDS")
  ->Dict.toArray
  ->Array.map(((table, v)) => (table, decodeEventFields(v)))
  ->Dict.fromArray

// ── Pure derivations ────────────────────────────────────────────────────────

/** Table name out of a stream ARN — `…:table/<TableName>/stream/<ts>`. */
let tableNameFromEventSourceArn = (arn: string): option<string> => {
  let parts = arn->String.split("/")
  switch (parts->Array.get(0), parts->Array.get(1), parts->Array.get(2)) {
  | (Some(prefix), Some(tableName), Some("stream")) if prefix->String.endsWith(":table") =>
    Some(tableName)
  | _ => None
  }
}

/** The ref strings a declared field holds in one event payload.

    Non-string values and the `""` sentinel (which `StorageRef` admits to mean
    "no object") yield nothing, so a field that is present but empty costs no
    S3 call. */
let refsOfField = (~data: dict<JSON.t>, field: refField): array<string> =>
  switch data->Dict.get(field.field) {
  | Some(String(ref)) if !field.many && ref != "" => [ref]
  | Some(Array(items)) if field.many =>
    items->Array.filterMap(v =>
      switch v {
      | String(ref) if ref != "" => Some(ref)
      | _ => None
      }
    )
  | _ => []
  }

/** Strip the leading `/` a ref carries (`/{prefix}/{key}`) to recover the S3
    object key. Mirrors the presign service, which mints `/${key}`. */
let keyOfRef = (storageRef: string): string =>
  storageRef->String.startsWith("/")
    ? storageRef->String.slice(~start=1, ~end=storageRef->String.length)
    : storageRef

/** An object this claim may touch: a declared store, and a key that actually
    sits under that store's served prefix.

    The prefix check is the same one the release rule makes, for the same
    reason — a ref that resolves outside the store it names is refused rather
    than acted on, so a malformed or hostile ref cannot steer an untag at an
    object the declaration does not cover. */
type target = {
  bucket: string,
  key: string,
}

let resolveTarget = (~store: string, ~storageRef: string): result<target, string> =>
  switch stores->Dict.get(store) {
  | None => Error(`unknown_store ${store}`)
  | Some({bucket, prefix}) =>
    let key = storageRef->keyOfRef
    key->String.startsWith(`${prefix}/`)
      ? Ok({bucket, key})
      : Error(`not_in_store ${store} ${storageRef}`)
  }

// ── The claim ───────────────────────────────────────────────────────────────

/** Remove the pending tag, keeping every other tag the object carries.
    Read-then-write rather than `DeleteObjectTagging`, which would take a
    deployment's own tags with it.

    Returns without writing when the tag is already absent — the replay case,
    and the common one — so a redelivered batch costs one read per object and
    no write. A missing object is success for the same reason a missing object
    is a successful release: the outcome asked for has already happened. */
let claim = async (~bucket: string, ~key: string): unit =>
  try {
    let current = await S3.GetObjectTaggingCommand.send(
      S3.GetObjectTaggingCommand.make({bucket, key}),
    )
    let tagSet = current.tagSet->Option.getOr([])
    let remaining = tagSet->Array.filter(t => t.key != Upload_PendingTag.key)
    if remaining->Array.length != tagSet->Array.length {
      let _ = await S3.PutObjectTaggingCommand.send(
        S3.PutObjectTaggingCommand.make({bucket, key, tagging: {tagSet: remaining}}),
      )
    }
  } catch {
  | exn =>
    switch exn->JsExn.fromException->Option.flatMap(JsExn.name) {
    | Some("NoSuchKey") | Some("NotFound") => ()
    | _ => throw(exn)
    }
  }

// ── DynamoDB stream event (only the fields this handler reads) ──────────────

type attributeValue = AwsSdk.DynamoDb.Util.attributeValue
type streamRecord = {@as("NewImage") newImage?: dict<attributeValue>}
type record = {
  eventName: string,
  eventSourceARN: string,
  dynamodb?: streamRecord,
}
type event = {@as("Records") records: array<record>}

/** The refs one stream record claims, already resolved to a bucket and key.

    Pure and separately testable: everything between "a row appeared" and "an
    S3 call happens" is decided here, so the untag itself has no branching left
    in it. */
let targetsOfRecord = (record: record): array<target> =>
  switch (
    record.eventSourceARN->tableNameFromEventSourceArn->Option.flatMap(t => refFieldsByTable->Dict.get(t)),
    record.dynamodb->Option.flatMap(d => d.newImage),
  ) {
  | (Some(byEventType), Some(image)) =>
    let row = AwsSdk.DynamoDb_Util_Helpers.unmarshallDict(image)
    // No `event` attribute → not an event row (a snapshot, a DCB fence row).
    switch (row->Dict.get("event")->Option.flatMap(JSON.Decode.string), row->Dict.get("data")) {
    | (Some(eventType), Some(JSON.Object(data))) =>
      byEventType
      ->Dict.get(eventType)
      ->Option.getOr([])
      ->Array.flatMap(field =>
        refsOfField(~data, field)->Array.filterMap(storageRef =>
          switch resolveTarget(~store=field.store, ~storageRef) {
          | Ok(target) => Some(target)
          | Error(why) =>
            // Refused, not acted on — and said out loud, because a ref that
            // does not resolve is a declaration and a deploy disagreeing.
            Console.error2("Upload_Claim: refusing ref outside a declared store —", why)
            None
          }
        )
      )
    | _ => []
    }
  | _ => []
  }

// ── Runtime handler ─────────────────────────────────────────────────────────

let handler = async (event: event): unit => {
  // An append-only log only ever inserts events; MODIFY rows are fence and
  // snapshot updates, which `targetsOfRecord` would drop anyway.
  let targets = event.records->Array.filter(r => r.eventName == "INSERT")->Array.flatMap(targetsOfRecord)
  // Sequential: a batch carries a handful of refs at most, and a failure must
  // reach the ESM as a throw so the record is retried rather than silently
  // leaving an object tagged.
  await targets->Array.reduce(Promise.resolve(), (acc, {bucket, key}) =>
    acc->Promise.then(_ => claim(~bucket, ~key))
  )
}
