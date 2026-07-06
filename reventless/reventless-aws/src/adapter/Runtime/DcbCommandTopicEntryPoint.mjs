// DcbCommandTopic Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports StateChangeSlice modules,
// builds shared DcbEventLog operations and per-slice handlers keyed by command type name.
// Dual routing: AppSync direct invocation and SQS CommandTopic events.

import * as Chunk from "effect/Chunk";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { patchSpecId, makeQueueRef, log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { decodeCommand$p as decodeCommandPrime } from "@reventlessdev/reventless-core/src/Message.res.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import {
  extractVariantNames,
  extractTagKeysByEventType,
  mergeTagKeysByEventType,
  extractCrossPartitionTagKeys,
} from "@reventlessdev/reventless-spec/src/components/DcbTag.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";
import { Make as dcbEventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res.mjs";
import { Make as stateChangeSliceCallbackMake } from "@reventlessdev/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res.mjs";
import { makeGenerateCommand } from "@reventlessdev/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res.mjs";
import { commandOutcomeToJson, runInlineAndCollect } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs";
import { json as jsonSchema } from "sury/src/S.res.mjs";
import { read, append, readStream } from "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res.mjs";
import { opsFor as pgDcbEventLogOpsFor } from "@reventlessdev/reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_Postgres_Runtime.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// DISPATCH_MODE controls whether AppSync direct-invoke commands are run inline
// (sync, default) or pushed to SQS for asynchronous processing (async).
// Set by PluginRuntime_Builder.forDcbCommandTopic when wiring the async DCB
// CommandTopic; sync is the default for the primary DCB topic.
const DISPATCH_MODE = process.env["DISPATCH_MODE"] === "async" ? "async" : "sync";

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

// Set at handler entry; read by runEffect to tag logs with the Lambda request id.
let _currentRequestId = "unknown";

function runEffect(correlationId, effect) {
  let e = effect
    // Promote correlationId/requestId/plugin to top-level JSON log fields —
    // decoded by EffectLogger.install() from Effect log annotations. Harmless
    // no-op if the unified logger isn't installed.
    .pipe(Effect.annotateLogs("correlationId", correlationId || "unknown"))
    .pipe(Effect.annotateLogs("requestId", _currentRequestId));
  if (pluginName) e = e.pipe(Effect.annotateLogs("plugin", pluginName));
  return e
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

// Exported for tests: build the [sqsHandler, cmdGenHandler] pair from an
// already-parsed `HANDLER_CONFIG` shape, with an injectable module loader.
// In production, `buildHandler` below wraps this with the env-config + the
// Lambda's `/var/task/node_modules` dynamic-import; integration tests inject
// their own loader that returns pre-imported spec/behavior modules so the test
// can drive the real `cmdGenHandler` end-to-end against DynamoDB Local.
export async function buildHandlersForConfig(config, opts = {}) {
  const loadModule = opts.loadModule ?? dynamicImport;
  // `pgConnection`, when present in HANDLER_CONFIG, selects the Postgres DCB
  // runtime (dcbEventLogTableName doubles as the `dcb_event.log_name`); absence
  // keeps the DynamoDB path byte-identical. NB: this swaps only the *storage*
  // ops — event propagation (within-plugin projections + cross-plugin SNS) is
  // stream-driven on AWS and is handled separately by the change-feed relay
  // (see docs/plans/aws-postgres-change-feed-bridge.md), not by this Lambda.
  const rawStorageOps = config.pgConnection
    ? (() => {
        // C2: `lockStrategy` ("AdvisoryLocks" | "RowLocks") is the polyvariant's
        // string name; `opsFor` defaults to "AdvisoryLocks" when it's absent.
        const pgOps = pgDcbEventLogOpsFor(
          config.pgConnection,
          config.dcbEventLogTableName,
          config.pgConnection.lockStrategy,
        );
        return { read: pgOps.read, append: pgOps.append, readStream: pgOps.readStream };
      })()
    : (() => {
        const resolvedTable = { name: config.dcbEventLogTableName };
        return {
          read: read(resolvedTable),
          append: append(resolvedTable),
          readStream: readStream(resolvedTable),
        };
      })();

  const handlersByType = {};
  const sharedDcbEventLogOps = dcbEventLogOperationsMake({
    name: config.pluginName,
    // Mirrors DcbEventLog_Builder.res's `name ++ "DcbEventLog"` — the
    // canonical service identity used by Plugin_Callback dispatch and the
    // DcbEventLog_Operations meta.service normalisation in append.
    serviceName: config.pluginName + "DcbEventLog",
    storage: rawStorageOps,
    publishJson: async (_name, _meta, _json) => {},
  });

  // Load all spec/behavior pairs first, then derive the per-plugin
  // tagKeysByEventType / crossPartitionTagKeys across the produced event
  // schemas — mirroring Dcb_Builder.res's build-time derivation — so the
  // runtime slice callback receives the same values it would in-process.
  const loadedSlices = await Promise.all(
    config.stateChangeSliceModules.map(async ({ spec, behavior }) => {
      const specModule = await loadModule(spec);
      const behaviorModule = await loadModule(behavior);
      const patchedSpec = patchSpecId(specModule);
      return { patchedSpec, behaviorModule };
    })
  );

  const producedSchemas = loadedSlices.map(({ patchedSpec }) => patchedSpec.eventSchema);
  const tagKeysByEventType = mergeTagKeysByEventType(
    producedSchemas.map(s => extractTagKeysByEventType(s))
  );
  const crossPartitionTagKeys = Array.from(
    new Set(producedSchemas.flatMap(s => extractCrossPartitionTagKeys(s)))
  );

  loadedSlices.forEach(({ patchedSpec, behaviorModule }) => {
    const sliceCallback = stateChangeSliceCallbackMake(patchedSpec)(behaviorModule);
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
      // Positional args match StateChangeSlice_Callback.res's compiled signature:
      // (tagKeysByEventTypeOpt, crossPartitionTagKeysOpt, dcbEventLog, stream).
      return sliceCallback.handleCommands(
        tagKeysByEventType,
        crossPartitionTagKeys,
        sharedDcbEventLogOps,
        decodedStream,
      );
    };

    typeNames.forEach(typeName => {
      handlersByType[typeName] = jsonHandler;
    });
  });

  // Composite handler used by Route 2 (SQS event source) AND inline dispatch
  // for Route 1 sync mode. Routes each item to the slice handler matching its
  // command TAG; unknown TAGs are dropped with a warning.
  const compositeJsonCommandsHandler = stream => Effect.map(
    Stream.runCollect(
      Stream.mapEffect(stream, topicItem => {
        const typeNameOpt = extractTypeName(topicItem.command);
        if (typeNameOpt !== undefined) {
          const sliceHandler = handlersByType[typeNameOpt];
          if (sliceHandler !== undefined) {
            return sliceHandler(Stream.make(topicItem));
          } else {
            log.warn("no handler for command type: " + typeNameOpt, { comp: "DcbCommandTopicRuntime" });
            return Effect.succeed([]);
          }
        }
        log.warn("could not extract command type", { comp: "DcbCommandTopicRuntime" });
        return Effect.succeed([]);
      })
    ),
    chunk => Chunk.toReadonlyArray(chunk).flat()
  );

  const resolvedQueue = makeQueueRef(config.queueUrl);
  const sqsHandler = handleQueueEvent(resolvedQueue, compositeJsonCommandsHandler);
  const publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO");

  // Sync (default): inline-dispatch the command via the same composite handler
  // that Route 2 uses, so the AppSync resolver gets a typed Accepted/Rejected
  // outcome. Async: undefined → makeGenerateCommand falls back to publishJsons
  // and returns Pending. The schema is permissive (S.json) because AppSync has
  // already validated input against the SDL — per-slice schemas reapply inside
  // the slice handlers via decodeCommandPrime.
  const publishJsonsAndWait = DISPATCH_MODE === "async"
    ? undefined
    : (jsons) => runInlineAndCollect(jsons, compositeJsonCommandsHandler);

  // Positional args match CommandGenerator_Callback.makeGenerateCommand's
  // ReScript-compiled signature: (publishJsons, publishJsonsAndWait,
  // serviceName, commandSchema, componentKind, stripIdFromParams).
  // stripIdFromParams=false: DCB slices may declare a literal `id` field as part
  // of the command schema (composite partition keys etc.) — don't strip it.
  const generateCommand = makeGenerateCommand(
    publishJsons,
    publishJsonsAndWait,
    config.pluginName,
    jsonSchema,
    "StateChangeSlice",
    false,
  );

  const cmdGenHandler = (event) => {
    // CommandGenerator.meta declares ip as array<string> (X-Forwarded-For chain).
    // AppSync sends a single string or null from identity.sourceIp.
    const rawIp = event.meta && event.meta.ip;
    const ip = rawIp == null ? [] : Array.isArray(rawIp) ? rawIp : [rawIp];
    const meta = { ...event.meta, ip };
    const identity = (event.identity != null && typeof event.identity === 'object')
      ? event.identity
      : {
          userId: (event.meta && event.meta.user) ?? "anonymous",
          username: (event.meta && event.meta.user) ?? "anonymous",
          groups: [],
          provider: { TAG: "Custom", _0: "aws" },
        };
    return generateCommand({ ...event, meta, identity });
  };

  return [sqsHandler, cmdGenHandler];
}

async function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"];
  // Importing this module without HANDLER_CONFIG (e.g. from a test that drives
  // `buildHandlersForConfig` directly) must not crash module evaluation.
  // Lambda always sets HANDLER_CONFIG; the production path is unchanged.
  if (!configStr) return [null, null];
  const config = JSON.parse(configStr);
  return buildHandlersForConfig(config, { loadModule: dynamicImport });
}

const initPromise = buildHandler();

export async function handler(event, context) {
  _currentRequestId = context?.awsRequestId || "unknown";
  const [sqsHandler, cmdGenHandler] = await initPromise;

  // Route 1: AppSync direct invocation — payload carries the CommandGenerator.payload
  // shape (`{command, arguments, meta, identity?}`).
  if (event.command != null && event.arguments != null) {
    log.debug("AppSync direct invocation (" + DISPATCH_MODE + ")", { comp: "DcbCommandTopicRuntime" });
    const outcome = await runEffect(undefined, cmdGenHandler(event));
    return commandOutcomeToJson(outcome);
  }

  // Route 2: SQS CommandTopic events
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  log.debug("processing " + records.length.toString() + " record(s)", { comp: "DcbCommandTopicRuntime" });
  await runEffect(correlationId, sqsHandler(event, context));
  return "";
}
