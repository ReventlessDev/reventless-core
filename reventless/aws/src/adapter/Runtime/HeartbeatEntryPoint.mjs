// Heartbeat Lambda handler.
// Publishes a Heartbeat(timeout) command to the PluginExtensionPoint CommandTopic.
// Triggered by CloudWatch Events on a schedule.

import { reverseConvertToJsonOrThrow } from "sury/src/S.res.mjs";
import { makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { uuid } from "@reventlessdev/reventless-core/src/Message.res.mjs";
import { name as pluginExtensionPointName, commandSchema } from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

// === Initialize eagerly at module load (Lambda cold start) ===

const epQueueUrl = process.env["EP_QUEUE_URL"] || "";
const pluginId = process.env["PLUGIN_ID"] || "";
const timeout = parseInt(process.env["HEARTBEAT_TIMEOUT"], 10) || 10;

const publishJsons = sqsPublishJsons(makeQueueRef(epQueueUrl), "SQS_FIFO");

// === Exported handler ===

export async function handler(_event, _context) {
  const msgId = uuid();
  const commandJson = reverseConvertToJsonOrThrow({ TAG: "Heartbeat", _0: timeout }, commandSchema);
  const message = {
    id: pluginId,
    meta: {
      service: pluginExtensionPointName,
      time: new Date().toISOString(),
      ip: "",
      user: "Heartbeat",
      msgId,
      correlationId: msgId,
    },
    commandJson,
  };
  await publishJsons([message]);
  return "";
}
