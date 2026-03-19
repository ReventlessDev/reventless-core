/**
 * Factory for reconstructing EventMapper handler chains in bundled Lambda handlers.
 *
 * The EventMapper subscribes to source aggregates' event logs (DynamoDB streams)
 * and maps events to commands for the target aggregate via user-defined Mappings.
 *
 * Handler chain (same as deploy-time):
 *   DynamoDB stream event
 *   → EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent
 *   → EventMapper_Callback.MakeEventCollectorHandler(Ops).handleJsonEvents
 *   → EventMapper_Callback.MakeCounterHandler(Target, Mappings, Ops).commonEventsHandler
 *   → findMapping → Mapping.map(id, event, queryEngine)
 *   → processMappingActions → publishJsons → SQS queue
 */

import {
  MakeCounterHandler,
  MakeEventCollectorHandler,
} from "@reventlessdev/reventless-core/src/components/EventMapper/EventMapper_Callback.res.mjs";
import { handleStreamEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res.mjs";
import { publishJsons as makePublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";

/**
 * Create an EventMapper handler for a single aggregate.
 *
 * @param {Object} targetSpecModule - Target aggregate Spec module (name, Id, commandSchema)
 * @param {Object} mappingsModule - Compiled Mappings module (mappings array, counter option)
 * @param {string} queueUrl - SQS FIFO queue URL for the target aggregate's CommandTopic
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createEventMapperHandler({
  targetSpecModule,
  mappingsModule,
  queueUrl,
}) {
  // Patch Target.Id — same issue as aggregate Spec.Id:
  // `module Id = Id.String` doesn't produce a runtime value in ESM exports.
  const patchedTarget = {
    ...targetSpecModule,
    Id: targetSpecModule.Id || IdString,
  };

  // Patch each mapping's Source.Id for the same reason.
  const patchedMappings = {
    ...mappingsModule,
    mappings: (mappingsModule.mappings || []).map((mapping) => ({
      ...mapping,
      Source: {
        ...mapping.Source,
        Id: mapping.Source.Id || IdString,
      },
    })),
  };

  // Reconstruct publishJsons from SQS queue URL.
  const resolvedQueue = { id: queueUrl, name: queueUrl, arn: "" };
  const publishJsons = makePublishJsons(resolvedQueue, "SQS_FIFO");

  // No-op queryEngine — mappings that use queryEngine will need explicit
  // configuration in a future enhancement (pass queryEngine table name).
  const queryEngine = {
    query: async () => {
      console.error(
        "EventMapper queryEngine not available in bundled mode — mapping returned no results"
      );
      return [];
    },
    get: async () => {
      console.error(
        "EventMapper queryEngine not available in bundled mode — mapping returned undefined"
      );
      return undefined;
    },
  };

  // MakeCounterHandler(Target)(Mappings)(Ops) — curried functor
  const counterHandler = MakeCounterHandler(patchedTarget)(patchedMappings)({
    publishJsons,
    queryEngine,
  });

  // No-op counter operations — Counter support in bundled EventMapper is TODO.
  const noopCount = async (_items) => {};
  const noopAddToCounterTarget = async (_target) => {};

  // MakeEventCollectorHandler(Ops) — single-argument functor
  const eventCollectorHandler = MakeEventCollectorHandler({
    publishJsons,
    count: noopCount,
    addToCounterTarget: noopAddToCounterTarget,
    commonEventsHandler: counterHandler.commonEventsHandler,
  });

  // Return handler wrapping DynamoDB stream event processing.
  // handleStreamEvent: (jsonEventsHandler, streamEvent, context) => Effect
  return (event, context) =>
    handleStreamEvent(eventCollectorHandler.handleJsonEvents, event, context);
}
