// Heartbeat Lambda entry point — compiled, type-checked ReScript (replaces the
// hand-written HeartbeatEntryPoint.mjs shell; no dynamic user-module import, so
// no untyped seam is needed).
//
// Publishes a Heartbeat(timeout) command to the PluginExtensionPoint
// CommandTopic. Triggered by CloudWatch Events on a schedule. Runtime-pure: no
// Pulumi value reaches this module's import graph (deploy-time wiring lives in
// PluginRuntime_Builder.forPluginHeartbeat).


// === Initialize eagerly at module load (Lambda cold start) ===

let epQueueUrl = NodeProcess.env->Dict.get("EP_QUEUE_URL")->Option.getOr("")
let pluginId = NodeProcess.env->Dict.get("PLUGIN_ID")->Option.getOr("")
// Mirrors the former shell's `parseInt(…) || 10`: unset, unparsable, and 0 all
// fall back to the 10-minute default.
let timeout =
  NodeProcess.env
  ->Dict.get("HEARTBEAT_TIMEOUT")
  ->Option.flatMap(s => Int.fromString(s))
  ->Option.filter(n => n != 0)
  ->Option.getOr(10)

let queue: Util_SQS_Runtime.resolvedQueue = {id: epQueueUrl, name: epQueueUrl, arn: ""}
let publishJsons = queue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO)

// === Exported handler ===

let handler = async (_event: JSON.t, _context: PulumiAws.Lambda.context) => {
  let message: ReventlessCore.Message.commandJson = {
    id: pluginId,
    meta: ReventlessCore.Message.generateMeta(
      ~service=ReventlessInfra.PluginExtensionPointSpec.name,
      ~ip="",
      ~user="Heartbeat",
    ),
    commandJson: ReventlessInfra.PluginExtensionPointSpec.Heartbeat(
      timeout,
    )->S.reverseConvertToJsonOrThrow(ReventlessInfra.PluginExtensionPointSpec.commandSchema),
  }
  await publishJsons([message])
  ""
}
