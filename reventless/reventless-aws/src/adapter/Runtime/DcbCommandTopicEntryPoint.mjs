// DcbCommandTopic Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports StateChangeSlice modules,
// builds shared DcbEventLog operations and per-slice handlers keyed by command type name.
// Dual routing: AppSync direct invocation and SQS CommandTopic events.

import * as Chunk from "effect/Chunk";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { patchSpecId, makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { decodeCommand$p as decodeCommandPrime, uuid } from "@reventlessdev/reventless-core/src/Message.res.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { extractVariantNames } from "@reventlessdev/reventless-spec/src/components/DcbTag.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import { Make as dcbEventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res.mjs";
import { Make as stateChangeSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res.mjs";
import { read, append, readStream } from "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

function extractTypeName(json) {
  if (typeof json === 'string') return json;
  if (json && typeof json === 'object') {
    const commandJson = json.commandJson || json.command || json;
    if (typeof commandJson === 'string') return commandJson;
    if (commandJson && commandJson.TAG) return commandJson.TAG;
    const keys = Object.keys(commandJson);
    if (keys.length === 1 && keys[0] !== 'id' && keys[0] !== 'meta') return keys[0];
  }
  return undefined;
}

function runEffect(correlationId, effect) {
  return effect
    .pipe(Effect.provideService(requestContextTag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);
}

function extractCorrelationId(records) {
  const first = records[0];
  if (!first) return undefined;
  const body = first.body;
  if (body == null) return undefined;
  try {
    const parsed = JSON.parse(body);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      const meta = parsed.meta;
      if (meta && typeof meta === "object" && !Array.isArray(meta)) {
        const cid = meta.correlationId;
        if (typeof cid === "string") return cid;
      }
    }
  } catch (_) {}
  return undefined;
}

function getIdStringSchema() {
  return IdString.schema;
}

async function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);
  const resolvedTable = { name: config.dcbEventLogTableName };
  const rawStorageOps = {
    read: read(resolvedTable),
    append: append(resolvedTable),
    readStream: readStream(resolvedTable),
  };

  const handlersByType = {};
  const sharedDcbEventLogOps = dcbEventLogOperationsMake({
    name: config.pluginName,
    storage: rawStorageOps,
    publishJson: async (_name, _meta, _json) => {},
  });

  await Promise.all(config.stateChangeSliceModules.map(async modPath => {
    const specModule = await dynamicImport(modPath);
    const patchedSpec = patchSpecId(specModule);
    const sliceCallback = stateChangeSliceCallbackMake(patchedSpec);
    const commandSchema = patchedSpec.commandSchema;
    const typeNames = extractVariantNames(commandSchema);

    const jsonHandler = stream => {
      const decodedStream = Stream.flatMap(
        Stream.mapEffect(stream, topicItem => Effect.sync(() => {
          try {
            const decoded = decodeCommandPrime(topicItem.command, getIdStringSchema(), commandSchema);
            return { TAG: "Some", _0: { command: decoded, reference: topicItem.reference } };
          } catch (_) {
            return { TAG: "None", _0: 0 };
          }
        })),
        opt => opt.TAG === "Some" ? Stream.make(opt._0) : Stream.empty
      );
      return sliceCallback.handleCommands(sharedDcbEventLogOps, decodedStream);
    };

    typeNames.forEach(typeName => {
      handlersByType[typeName] = jsonHandler;
    });
  }));

  const compositeJsonCommandsHandler = stream => Effect.map(
    Stream.runCollect(
      Stream.mapEffect(stream, topicItem => {
        const typeNameOpt = extractTypeName(topicItem.command);
        if (typeNameOpt !== undefined) {
          const sliceHandler = handlersByType[typeNameOpt];
          if (sliceHandler !== undefined) {
            return sliceHandler(Stream.make(topicItem));
          } else {
            console.warn("DCB: no handler for command type: " + typeNameOpt);
            return Effect.succeed([]);
          }
        }
        console.warn("DCB: could not extract command type");
        return Effect.succeed([]);
      })
    ),
    chunk => Chunk.toReadonlyArray(chunk).flat()
  );

  const resolvedQueue = makeQueueRef(config.queueUrl);
  const sqsHandler = handleQueueEvent(resolvedQueue, compositeJsonCommandsHandler);

  function mkCmdGenHandler(publishFn, pluginName) {
    return function(payload) {
      const msgId = crypto.randomUUID();
      const args = payload.arguments;
      let id = args.id;
      if (!id) {
        for (const key of Object.keys(args)) {
          if (key.endsWith('Id') && typeof args[key] === 'string') { id = args[key]; break; }
        }
      }
      if (!id) id = msgId;
      const ip = payload.meta && payload.meta.ip && Array.isArray(payload.meta.ip) ? payload.meta.ip[0] || "" : "";
      const user = payload.meta && payload.meta.user ? payload.meta.user : "";
      const meta = { service: pluginName, time: new Date().toISOString(), ip, user, msgId, correlationId: msgId };
      const obj = JSON.parse(JSON.stringify(args));
      delete obj.id;
      const params = Object.entries(obj);
      const commandJson = params.length > 0 ? Object.fromEntries([["TAG", payload.command]].concat(params)) : payload.command;
      return publishFn([{ id, meta, commandJson }]).then(function() { return msgId; });
    };
  }

  const publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO");
  const cmdGenHandler = mkCmdGenHandler(publishJsons, config.pluginName);

  return [sqsHandler, cmdGenHandler];
}

const initPromise = buildHandler();

export async function handler(event, context) {
  const [sqsHandler, cmdGenHandler] = await initPromise;

  // Route 1: AppSync direct invocation
  if (event.command != null && event.arguments != null) {
    console.log("----- dcbCommandTopicHandler: AppSync direct invocation");
    return await cmdGenHandler(event);
  }

  // Route 2: SQS CommandTopic events
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  console.log("----- dcbCommandTopicHandler: processing " + records.length.toString() + " record(s)");
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
