// Compiled entry point for heartbeat Lambda handler.
// Publishes a Heartbeat(timeout) command to the PluginExtensionPoint CommandTopic.
// Triggered by CloudWatch Events on a schedule.
// No user modules — all imports are from framework packages in the Lambda Layer.

// === Process environment ===
@scope("process") @val external env: dict<string> = "env"

// === Build-verified imports ===

@module(
  "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs"
)
external sqsPublishJsons: ('a, string) => 'b = "publishJsons"

@module("@reventlessdev/reventless-core/src/Message.res.mjs")
external messageUuid: unit => string = "uuid"

@module("@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs")
external pluginExtensionPointName: string = "name"

@module("@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs")
external commandSchema: 'a = "commandSchema"

@module("sury/src/S.res.mjs")
external reverseConvertToJsonOrThrow: ('a, 'b) => JSON.t = "reverseConvertToJsonOrThrow"

@module("./HandlerFactoryHelpers.res.mjs")
external makeQueueRef: string => 'a = "makeQueueRef"

// === Object constructors ===

let mkHeartbeatVariant: int => 'a = %raw(`(timeout) => ({TAG: "Heartbeat", _0: timeout})`)

let mkMessage: (string, string, string, string, JSON.t) => 'a = %raw(`
  (id, service, msgId, correlationId, commandJson) => ({
    id,
    meta: {
      service,
      time: new Date().toISOString(),
      ip: "",
      user: "Heartbeat",
      msgId,
      correlationId,
    },
    commandJson,
  })
`)

let callPublish: ('a, array<'b>) => promise<unit> = %raw(`(fn, msgs) => fn(msgs)`)

// === Initialize handler eagerly at module load ===

let epQueueUrl = env->Dict.get("EP_QUEUE_URL")->Option.getOr("")
let pluginId = env->Dict.get("PLUGIN_ID")->Option.getOr("")
let timeout =
  env->Dict.get("HEARTBEAT_TIMEOUT")->Option.flatMap(s => Int.fromString(s))->Option.getOr(10)

let publishJsons = sqsPublishJsons(makeQueueRef(epQueueUrl), "SQS_FIFO")

// === Exported handler ===

let handler = async (_event, _context) => {
  let msgId = messageUuid()
  let commandJson = reverseConvertToJsonOrThrow(commandSchema, mkHeartbeatVariant(timeout))
  let message = mkMessage(pluginId, pluginExtensionPointName, msgId, msgId, commandJson)
  let _ = await callPublish(publishJsons, [message])
  ""
}
