/**
 * Factory for reconstructing the Heartbeat handler in bundled Lambda handlers.
 *
 * The heartbeat handler publishes a Heartbeat(timeout) command to the
 * PluginExtensionPoint CommandTopic (SQS FIFO queue) on each invocation.
 * CloudWatch Events triggers this Lambda on a schedule (every N minutes).
 *
 * Handler chain:
 *   CloudWatch Event → handler → publishJsons([{id, meta, commandJson: Heartbeat(timeout)}])
 */

import { publishJsons as makePublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import * as Message from "@reventlessdev/reventless-core/src/Message.res.mjs";
import * as PluginExtensionPointSpec from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import { reverseConvertToJsonOrThrow } from "sury/src/S.res.mjs";

/**
 * Create a heartbeat handler.
 *
 * @param {string} epQueueUrl - PluginExtensionPoint CommandTopic SQS FIFO queue URL
 * @param {string} pluginId - Plugin ID string
 * @param {number} timeout - Heartbeat timeout in minutes
 * @returns {Function} handler: (event, context) => Promise<void>
 */
export function createHeartbeatHandler({ epQueueUrl, pluginId, timeout }) {
  const resolvedQueue = { id: epQueueUrl, name: epQueueUrl, arn: "" };
  const publishJsons = makePublishJsons(resolvedQueue, "SQS_FIFO");

  return async (_event, _context) => {
    const msgId = Message.uuid();
    const commandJson = reverseConvertToJsonOrThrow(
      PluginExtensionPointSpec.commandSchema,
      { TAG: "Heartbeat", _0: timeout }
    );

    await publishJsons([
      {
        id: pluginId,
        meta: {
          service: PluginExtensionPointSpec.name,
          time: new Date().toISOString(),
          ip: "",
          user: "Heartbeat",
          msgId,
          correlationId: msgId,
        },
        commandJson,
      },
    ]);
  };
}
