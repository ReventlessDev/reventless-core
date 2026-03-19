/**
 * Factory for reconstructing aggregate handler chains in bundled Lambda handlers.
 *
 * At deploy time, handler closures capture infrastructure references (table names,
 * queue URLs) and business logic (Spec, Behavior modules) via Pulumi Output chains.
 * In bundled Lambdas, these values come from environment variables and static imports
 * instead. This module provides factory functions that reconstruct the same handler
 * chain from those inputs.
 *
 * Handler chain (same as deploy-time):
 *   SQS event
 *   → CommandTopicChannel_SQS_Runtime.handleQueueEvent(queue, handleJsonCommands)
 *   → CommandTopic_Callback.Make(Spec)(Ops).handleJsonCommands
 *   → Aggregate_Callback.Make(Spec)(Behavior)(EventLogOps).handleCommands
 *   → EventLog_Operations.Make(Spec)(Ops).{append, replayStream}
 *   → EventLogStorage_DynamoDb_Runtime.{append, replayStream}
 */

import { Make as AggregateCallbackMake } from "@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs";
import { Make as CommandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { Make as EventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/EventLog/EventLog_Operations.res.mjs";
import * as EventLogRuntime from "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs";
import { handleQueueEvent } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";

/**
 * Create a commandTopic handler for a single aggregate.
 *
 * @param {Object} specModule - Compiled Spec module (must export: name, commandSchema, eventSchema, errorSchema)
 * @param {Object} behaviorModule - Compiled Behavior module (must export: apply, init, create, execute, resolverConfig)
 * @param {string} eventLogTableName - DynamoDB table name for the event log
 * @param {string} queueUrl - SQS queue URL (used for deleting processed messages)
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createCommandTopicHandler({
  specModule,
  behaviorModule,
  eventLogTableName,
  queueUrl,
}) {
  // ReScript compiles `module Id = Id.String` as a module alias that doesn't
  // produce a runtime value in the ESM export. The functor expects Spec.Id
  // with schema/toString/makeFromString, so we supply it from the Id package.
  // TODO: support other Id types by passing the Id module path in the config.
  const patchedSpec = { ...specModule, Id: specModule.Id || IdString };

  // Build a resolvedTable-like object with the table name.
  // EventLogStorage_DynamoDb_Runtime functions only use table.name.
  const resolvedTable = { name: eventLogTableName };

  // Raw storage operations — direct DynamoDB read/write without serialization.
  const rawStorageOps = {
    append: EventLogRuntime.append(resolvedTable),
    replay: EventLogRuntime.replay(resolvedTable),
    replayStream: EventLogRuntime.replayStream(resolvedTable),
    appendStream: EventLogRuntime.appendStream(resolvedTable),
  };

  // No-op event topic — with DynamoDbStream, events are published via the
  // DynamoDB stream trigger, not explicit publish calls.
  const noopEventTopicOps = {
    publish: async (_events) => {},
  };

  // Wrap raw storage with EventLog_Operations.Make which handles:
  // - Event serialization (id + sequenceNr + type + data + meta → DynamoDB item)
  // - Event deserialization (DynamoDB item → typed event)
  // - Retry logic for transient DynamoDB errors
  // - Event topic publishing after successful append
  const eventLogOps = EventLogOperationsMake(patchedSpec)({
    Spec: patchedSpec,
    EventTopic: { Spec: patchedSpec },
    eventTopic: noopEventTopicOps,
    storage: rawStorageOps,
  });

  // Apply the functor chain:
  // Aggregate_Callback.Make(Spec)(Behavior)({Spec, EventLog: {Spec}, eventLog})
  const aggregateCallback = AggregateCallbackMake(patchedSpec)(behaviorModule)({
    Spec: patchedSpec,
    EventLog: { Spec: patchedSpec },
    eventLog: eventLogOps,
  });

  // CommandTopic_Callback.Make(Spec)({Spec, commandsHandler})
  const commandTopicCallback = CommandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: aggregateCallback.handleCommands,
  });

  // Build a resolvedQueue-like object for SQS message deletion.
  // Util_SQS_Runtime.deleteMessages uses queue.id (which is the queue URL).
  const resolvedQueue = { id: queueUrl, name: queueUrl, arn: "" };

  // Wire up the SQS handler
  return handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands);
}
