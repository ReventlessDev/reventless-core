// Runtime handler for the EventLog → AppSync Events subscription relay —
// compiled, type-checked ReScript (replaces the inline JS `makeHandlerCode`
// string in EventLogSubscription_AppSync.res). Runtime-pure and SDK-free: it
// signs with node:crypto via AppSyncEventsSigner_Ops (see the parity test).
//
// Triggered by SQS (SNS event-topic fan-in). For each record it parses the SNS
// body, wraps it as a `{position, eventType, payload}` event, and publishes it
// to the fixed plugin event-log channel on the AppSync Events API.


// Baked at deploy time: the normalised channel segment for this event log.
let channel = "/default/" ++ NodeProcess.env->Dict.get("EVENT_LOG_CHANNEL")->Option.getOr("")
let endpoint = NodeProcess.env->Dict.get("APPSYNC_ENDPOINT")->Option.getOr("")

// SQS Lambda event (only the fields this handler reads).
type sqsRecord = {body: string, messageId: string}
type sqsEvent = {@as("Records") records: array<sqsRecord>}

let processRecord = async (
  ~record: sqsRecord,
  ~region: string,
  ~creds: AppSyncEventsSigner_Ops.creds,
): unit => {
  let parsed = try Some(record.body->JSON.parseOrThrow) catch {
  | _ => None
  }
  switch parsed->Option.flatMap(JSON.Decode.object) {
  | None => Console.error2("EventLogSubscription: failed to parse record body", record.body)
  | Some(body) =>
    // Wrap as {position, eventType, payload}; omit fields absent on the source
    // body (matches the former JS, where `undefined` fields drop from JSON).
    let payload = Dict.make()
    body->Dict.get("position")->Option.forEach(v => payload->Dict.set("position", v))
    body->Dict.get("eventType")->Option.forEach(v => payload->Dict.set("eventType", v))
    body->Dict.get("data")->Option.forEach(v => payload->Dict.set("payload", v))
    let reqBody =
      Dict.fromArray([
        ("id", JSON.Encode.string(record.messageId)),
        ("channel", JSON.Encode.string(channel)),
        ("events", JSON.Encode.array([JSON.Encode.string(payload->JSON.Encode.object->JSON.stringify)])),
      ])
      ->JSON.Encode.object
      ->JSON.stringify
    let res = await AppSyncEventsSigner_Ops.postEvent(
      ~endpoint,
      ~region,
      ~isoNow=Date.make()->Date.toISOString,
      ~creds,
      ~body=reqBody,
    )
    if !(res->AppSyncEventsSigner_Ops.responseOk) {
      let txt = await res->AppSyncEventsSigner_Ops.responseText
      Console.error3(
        "EventLogSubscription publish failed:",
        res->AppSyncEventsSigner_Ops.responseStatus->Int.toString,
        txt,
      )
    }
  }
}

let handler = async (event: sqsEvent): unit => {
  let region = AppSyncEventsSigner_Ops.region()
  let creds = AppSyncEventsSigner_Ops.envCreds()
  // Sequential, mirroring the former for-await loop (order + at-least-once).
  await event.records->Array.reduce(Promise.resolve(), (acc, record) =>
    acc->Promise.then(_ => processRecord(~record, ~region, ~creds))
  )
}
