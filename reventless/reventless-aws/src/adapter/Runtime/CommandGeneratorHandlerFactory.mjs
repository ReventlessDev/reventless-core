/**
 * Factory for reconstructing CommandGenerator handler chains in bundled Lambda handlers.
 *
 * Handler chain (same as deploy-time):
 *   AppSync payload (command, arguments, meta)
 *   → CommandGenerator_Callback.makeGenerateCommand(publishJsons, serviceName, commandSchema)
 *   → validates command against schema
 *   → publishJsons([{id, meta, commandJson}]) → SQS queue
 */

import { makeGenerateCommand } from "@reventlessdev/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res.mjs";
import { publishJsons as makePublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

/**
 * Create a CommandGenerator handler for a single aggregate.
 *
 * @param {Object} specModule - Compiled Spec module (must export: name)
 * @param {Object} behaviorModule - Compiled Behavior module (must export: resolverConfig.commandSchema)
 * @param {string} queueUrl - SQS FIFO queue URL for the aggregate's CommandTopic
 * @returns {Function} Handler: (event, context) => Effect.t<string, unit, unit>
 */
export function createCommandGeneratorHandler({
  specModule,
  behaviorModule,
  queueUrl,
}) {
  // Build a resolvedQueue-like object for SQS message sending.
  // CommandTopicChannel_SQS_Runtime.publishJsons uses queue.id (the URL).
  const resolvedQueue = { id: queueUrl, name: queueUrl, arn: "" };
  const publishJsons = makePublishJsons(resolvedQueue, "SQS_FIFO");

  // makeGenerateCommand(publishJsons, serviceName, commandSchema, stripIdFromParams?)
  const generateCommand = makeGenerateCommand(
    publishJsons,
    specModule.name,
    behaviorModule.resolverConfig.commandSchema,
    undefined // stripIdFromParams defaults to true
  );

  // The CommandGenerator handler receives an AppSync payload and returns an Effect.
  // generateCommand: (payload) => Effect.t<string, unit, unit>
  return (event, _context) => generateCommand(event);
}
