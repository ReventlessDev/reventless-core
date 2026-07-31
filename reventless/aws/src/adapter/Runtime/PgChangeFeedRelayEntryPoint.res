// PgChangeFeedRelay Lambda entry point (scheduled poll — B2.3) — compiled,
// type-checked ReScript (replaces the hand-written PgChangeFeedRelayEntryPoint.mjs
// shell; no dynamic user-module import, so no untyped seam is needed).
//
// Triggered on a schedule (EventBridge rate rule). Each invocation drains every
// Postgres log listed in HANDLER_CONFIG from its checkpoint — DCB (`dcb_event`)
// and classic aggregate (`event_log`) logs alike — and relays the events,
// transformed into the {id, meta, event} shape, onto the plugin EventCollector
// SQS queue — which then fans out to projections, aggregate command topics, and
// the cross-plugin SNS EventTopic.
// See docs/plans/done/aws-postgres-change-feed-bridge.md.
//
// Runtime-pure: `PgConnection.connectionConfig` is referenced as a type only
// (erased — no runtime import of the Pulumi-carrying PgConnection module);
// PgChangeFeedRelay_Runtime/Util_SQS_Runtime are runtime modules. Deploy-time
// wiring lives in PgChangeFeedRelay_Builder.
//
// HANDLER_CONFIG shape:
//   { "logs": [ { "pgConnection": {host,port,database,username,secretArn},
//                 "logName": string,          // dcb_event/event_log log_name
//                 "subscriber": string,        // per-log checkpoint key
//                 "targetQueueUrl": string,    // plugin EventCollector SQS URL
//                 "kind"?: "classic",          // absent → DCB
//                 "partitionTag"?: <derivedPartitionTag> } ] }  // DCB only


// Structured JSON logging shared by every deployed entry point (HandlerFactoryHelpers).
type logExtra = {comp?: string}
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logDebug: (string, logExtra) => unit = "debug"
@module("./HandlerFactoryHelpers.mjs") @scope("log")
external logWarn: (string, logExtra) => unit = "warn"

type relayLogConfig = {
  pgConnection: PgConnection.connectionConfig,
  logName: string,
  subscriber: string,
  targetQueueUrl: string,
  // Absent → DCB (`dcb_event`); "classic" → aggregate `event_log`.
  kind?: string,
  // DCB only: the sury-encoded derived partition tag (parsed inside relayWithPool).
  partitionTag?: JSON.t,
}
type handlerConfig = {logs?: array<relayLogConfig>}
@val @scope("JSON") external parseHandlerConfig: string => handlerConfig = "parse"

// Standard (non-FIFO) EventCollector queue — no message group id needed. The
// SQS handler parses each body straight back to JSON (Util_SQS_Runtime.parseSqsRecord).
let makeSendBatch = (targetQueueUrl: string): (array<JSON.t> => promise<unit>) => {
  let queue: Util_SQS_Runtime.resolvedQueue = {id: targetQueueUrl, name: targetQueueUrl, arn: ""}
  jsons =>
    jsons
    ->Array.map(json => Util_SQS_Runtime.sendMessage(queue, json->JSON.stringify))
    ->Promise.all
    ->Promise.thenResolve(_ => ())
}

// Drain one log and relay it. Log-and-continue on failure — a failed log this
// tick is retried next tick from its unchanged checkpoint (at-least-once;
// projections are idempotent).
let relayLog = async (l: relayLogConfig): unit => {
  let sendBatch = makeSendBatch(l.targetQueueUrl)
  try {
    let count = switch l.kind {
    | Some("classic") =>
      await PgChangeFeedRelay_Runtime.relayClassic(
        ~config=l.pgConnection,
        ~logName=l.logName,
        ~subscriber=l.subscriber,
        ~sendBatch,
      )
    | _ =>
      await PgChangeFeedRelay_Runtime.relay(
        ~config=l.pgConnection,
        ~logName=l.logName,
        ~subscriber=l.subscriber,
        ~partitionTagJson=?l.partitionTag,
        ~sendBatch,
      )
    }
    logDebug(`relayed ${count->Int.toString} event(s) for ${l.logName}`, {comp: "PgChangeFeedRelay"})
  } catch {
  | exn =>
    let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")
    logWarn(`relay failed for ${l.logName}: ${msg}`, {comp: "PgChangeFeedRelay"})
  }
}

let handler = async (_event: JSON.t, _context: PulumiAws.Lambda.context) => {
  let config =
    NodeProcess.env->Dict.get("HANDLER_CONFIG")->Option.getOr(`{"logs":[]}`)->parseHandlerConfig
  let logs = config.logs->Option.getOr([])
  let _ = await logs->Array.map(relayLog)->Promise.all
  ""
}
