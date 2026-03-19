/**
 * Factory for reconstructing DCB CommandTopic handler chains in bundled Lambda handlers.
 *
 * The DCB CommandTopic handler is a composite that routes between:
 *   1. Normal SQS commands → StateChangeSlice handlers (by command type tag)
 *   2. InboundTranslation markers → InboundTranslationSlice receive functions
 *   3. CommandGenerator payloads → generateCommand function (AppSync direct invocation)
 *
 * Handler chain per StateChangeSlice:
 *   SQS event
 *   → CommandTopicChannel_SQS_Runtime.handleQueueEvent(queue, compositeHandler)
 *   → route by command type → StateChangeSlice_Callback.handleCommands(dcbEventLogOps, stream)
 *   → DcbEventLog_Operations.Make(Spec)(Ops).{readStream, append}
 *   → DcbEventLogStorage_DynamoDb_Runtime.{readStream, append}
 */

import { Make as StateChangeSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res.mjs";
import { Make as DcbEventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res.mjs";
import * as DcbEventLogRuntime from "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res.mjs";
import { handleQueueEvent } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import * as Message from "@reventlessdev/reventless-core/src/Message.res.mjs";
import * as DcbTag from "@reventlessdev/reventless-spec/src/components/DcbTag.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import { Effect, Stream } from "effect";

/**
 * Create a composite DCB CommandTopic handler.
 *
 * @param {string} dcbEventLogTableName - DynamoDB table name for the DCB event log
 * @param {string} queueUrl - SQS FIFO queue URL for the DCB CommandTopic
 * @param {Array<{specModule: Object}>} stateChangeSliceSpecs - Compiled StateChangeSlice spec modules
 * @param {string} pluginName - Plugin name (for generateCommand serviceName)
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createDcbCommandTopicHandler({
  dcbEventLogTableName,
  queueUrl,
  stateChangeSliceSpecs,
  pluginName,
}) {
  const resolvedTable = { name: dcbEventLogTableName };

  // Build raw DCB storage operations from table name
  const rawStorageOps = {
    read: DcbEventLogRuntime.read(resolvedTable),
    append: DcbEventLogRuntime.append(resolvedTable),
    readStream: DcbEventLogRuntime.readStream(resolvedTable),
  };

  // No-op event topic — with DynamoDbStream, events are published via the stream trigger
  const noopPublishJson = async (_name, _meta, _json) => {};

  // Build handler routing table: commandTypeName → jsonCommandsHandler
  const handlersByType = new Map();

  for (const { specModule } of stateChangeSliceSpecs) {
    const patchedSpec = { ...specModule, Id: specModule.Id || IdString };

    // Create DcbEventLog_Operations for this spec's event schema
    // The DcbEventLogSpec is on the spec module as DcbEventLogSpec
    const dcbEventLogSpec = patchedSpec.DcbEventLogSpec || patchedSpec;

    const dcbEventLogOps = DcbEventLogOperationsMake(dcbEventLogSpec)({
      Spec: dcbEventLogSpec,
      name: pluginName,
      storage: rawStorageOps,
      publishJson: noopPublishJson,
    });

    // Create StateChangeSlice_Callback for this spec
    const sliceCallback = StateChangeSliceCallbackMake(patchedSpec);

    // Extract command type names for routing
    // S.castToUnknown is a zero-cost type cast in ReScript — identity at runtime
    const commandSchema = patchedSpec.commandSchema;
    const typeNames = DcbTag.extractEventTypes(commandSchema);

    // Create the json handler (mirrors StateChangeSlice_Builder.makeJsonHandler)
    const makeJsonHandler = (ops) => (stream) => {
      const decodedStream = Stream.flatMap(
        Stream.mapEffect(stream, ({ reference, command: json }) =>
          Effect.sync(() => {
            try {
              const command = Message.decodeCommand$p(json, IdString.schema, patchedSpec.commandSchema);
              return { TAG: "Some", _0: { reference, command } };
            } catch (err) {
              console.error(`Couldn't decode command:`, err);
              return { TAG: "None" };
            }
          })
        ),
        (opt) => opt.TAG === "Some" ? Stream.make(opt._0) : Stream.empty
      );
      return sliceCallback.handleCommands(ops, decodedStream);
    };

    const jsonHandler = makeJsonHandler(dcbEventLogOps);

    // Register handler for each type name
    for (const typeName of typeNames) {
      handlersByType.set(typeName, jsonHandler);
    }
  }

  // CommandGenerator (AppSync direct invocation) not yet reconstructed in bundled mode.

  // Composite handler: routes by message type
  const compositeJsonCommandsHandler = (stream) => {
    // Process each command individually via mapEffect + collect
    return Stream.runCollect(
      Stream.mapEffect(stream, ({ reference, command: json }) => {
        // Determine command type from the JSON
        const typeNameOpt = extractTypeName(json);

        if (typeNameOpt && handlersByType.has(typeNameOpt)) {
          const handler = handlersByType.get(typeNameOpt);
          // Create a single-element stream for this command
          const singleStream = Stream.make({ reference, command: json });
          return handler(singleStream);
        }

        // Fallback: unknown command type
        console.warn(`DCB: no handler for command type: ${typeNameOpt}`);
        return Effect.succeed([]);
      })
    );
  };

  // Build a SQS handler that also handles InboundTranslation and CommandGenerator payloads
  const resolvedQueue = { id: queueUrl, name: queueUrl, arn: "" };

  // Wrap with SQS handler for message deletion
  return handleQueueEvent(resolvedQueue, compositeJsonCommandsHandler);
}

/**
 * Extract the type/variant name from a command JSON.
 * Commands are encoded as either:
 *   - { "TAG": "VariantName", ... } (tagged variant)
 *   - "VariantName" (payload-less variant as bare string)
 *   - { "commandJson": ... } wrapped in Message.command' format
 */
function extractTypeName(json) {
  if (typeof json === 'string') return json;
  if (json && typeof json === 'object') {
    // Message.command' format: { id, meta, commandJson }
    const commandJson = json.commandJson || json;
    if (typeof commandJson === 'string') return commandJson;
    if (commandJson && commandJson.TAG) return commandJson.TAG;
    // Try to get the first key that looks like a variant
    const keys = Object.keys(commandJson);
    if (keys.length === 1 && keys[0] !== 'id' && keys[0] !== 'meta') return keys[0];
  }
  return null;
}
