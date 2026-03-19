/**
 * Factory for reconstructing ExtensionPoint handler chains in bundled Lambda handlers.
 *
 * Handler chain (same as deploy-time):
 *   SQS event (CommandTopic)
 *   → CommandTopicChannel_SQS_Runtime.handleQueueEvent(queue, handleJsonCommands)
 *   → CommandTopic_Callback.Make(Spec)(Ops).handleJsonCommands  (decodes JSON commands)
 *   → ExtensionPoint_Callback.Make(Config)(Spec)(Mappings).handleIncomingCommands  (maps + applies)
 *   → applyCommandAction → publishToAggregates[aggregateName](commands)
 */

import { Make as ExtensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as CommandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { handleQueueEvent } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { publishJsons as makePublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";

/**
 * Create an ExtensionPoint CommandTopic handler.
 *
 * @param {Object} specModule - Compiled ExtensionPoint Spec module (command, event, directive schemas)
 * @param {Object} mappingsModule - Compiled Mappings module (mappings array)
 * @param {Object} publishToAggregatesEnv - Map of aggregate name → SQS FIFO queue URL
 * @param {string} queueUrl - ExtensionPoint's own CommandTopic SQS queue URL (for message deletion)
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createExtensionPointHandler({
  specModule,
  mappingsModule,
  publishToAggregatesEnv,
  queueUrl,
}) {
  // Patch Id module — same as aggregates
  const patchedSpec = { ...specModule, Id: specModule.Id || IdString };

  // Reconstruct publishToAggregates dict from env var queue URLs
  const publishToAggregates = {};
  for (const [aggName, aggQueueUrl] of Object.entries(publishToAggregatesEnv)) {
    const queue = { id: aggQueueUrl, name: aggQueueUrl, arn: "" };
    publishToAggregates[aggName] = makePublishJsons(queue, "SQS_FIFO");
  }

  // No-op scheduler — throws if actually called.
  // TODO: Reconstruct from S3 bucket env var if mappings use scheduling.
  const scheduler = {
    create: async () => {
      throw new Error("Scheduler not available in bundled ExtensionPoint handler");
    },
    delete: async () => {
      throw new Error("Scheduler not available in bundled ExtensionPoint handler");
    },
  };

  // No-op queryEngine — throws if actually called.
  // TODO: Reconstruct from DynamoDB table env vars if mappings use queries.
  const queryEngine = {
    scan: async () => {
      throw new Error("QueryEngine not available in bundled ExtensionPoint handler");
    },
    query: async () => {
      throw new Error("QueryEngine not available in bundled ExtensionPoint handler");
    },
  };

  // ResourceNaming — minimal implementation for bundled mode
  const resourceNaming = {
    name: (n) => n,
    resolve: (n) => n,
  };

  // Empty commandTopicResources — only needed for scheduler integration
  const commandTopicResources = [];

  // Apply ExtensionPoint_Callback.Make(config)(spec)(mappings)
  const callbackConfig = {
    publishToAggregates,
    commandTopicResources,
    scheduler,
    queryEngine,
    resourceNaming,
  };
  const callback = ExtensionPointCallbackMake(callbackConfig)(patchedSpec)(mappingsModule);

  // Apply CommandTopic_Callback.Make(patchedSpec)({Spec, commandsHandler})
  const commandTopicCallback = CommandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: callback.handleIncomingCommands,
  });

  // Wire up SQS handler — extracts messages, calls handler, deletes processed messages
  const resolvedQueue = { id: queueUrl, name: queueUrl, arn: "" };
  return handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands);
}
