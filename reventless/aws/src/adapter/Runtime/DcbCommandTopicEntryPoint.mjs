// DcbCommandTopic Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports StateChangeSlice modules,
// builds shared DcbEventLog operations and per-slice handlers keyed by command type name.
// Dual routing: AppSync direct invocation and SQS CommandTopic events.

import * as Chunk from "effect/Chunk";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { patchSpecId, makeQueueRef, log, pluginName } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as dcbEventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res.mjs";
import { makeCommandGenerator } from "./CommandGeneratorEntryPoint_Ops.res.mjs";
import { commandOutcomeToJson, runInlineAndCollect } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs";
import { json as jsonSchema } from "sury/src/S.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
// Typed cold-start core — scope/partitionTag derivation, storage-ops wiring, and
// per-slice handler building (functor + decode + handleCommands), all
// compiler-checked against the framework signatures (see the module header and
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md).
import { deriveScope, commandTypeNames, makeStorageOps, buildSliceHandler } from "./DcbCommandTopicEntryPoint_Ops.res.mjs";

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

// Exported for tests: build the [sqsHandler, cmdGenHandler] pair from an
// already-parsed `HANDLER_CONFIG` shape, with an injectable module loader.
// In production, `buildHandler` below wraps this with the env-config + the
// Lambda's `/var/task/node_modules` dynamic-import; integration tests inject
// their own loader that returns pre-imported spec/behavior modules so the test
// can drive the real `cmdGenHandler` end-to-end against DynamoDB Local.
export async function buildHandlersForConfig(config, opts = {}) {
  const loadModule = opts.loadModule ?? dynamicImport;

  // Untyped boundary: dynamically import + id-patch the user Spec/Behavior
  // modules. Their types are unknowable here — this is the one seam the typed
  // core (below) cannot own, so it stays in the shell.
  const loadedSlices = await Promise.all(
    config.stateChangeSliceModules.map(async ({ spec, behavior }) => {
      const specModule = await loadModule(spec);
      const behaviorModule = await loadModule(behavior);
      return { patchedSpec: patchSpecId(specModule), behaviorModule };
    })
  );

  // Typed core: scope (crossPartitionTagKeys / tagKeysByEventType) + storage
  // `partitionTag` derivation and backend-specific storage-ops wiring, all
  // compiler-checked against the framework signatures — the single source of
  // truth shared with Dcb_Builder.res. The two prod incidents this prevents are
  // documented in DcbCommandTopicEntryPoint_Ops.res. `pgConnection`, when present
  // in HANDLER_CONFIG, selects the Postgres backend (dcbEventLogTableName doubles
  // as `dcb_event.log_name`); absence keeps the DynamoDB path byte-identical.
  const specs = loadedSlices.map(({ patchedSpec }) => patchedSpec);
  const scope = deriveScope(specs);
  const { crossPartitionTagKeys, tagKeysByEventType } = scope;
  const rawStorageOps = makeStorageOps(
    config.dcbEventLogTableName,
    config.pgConnection,
    scope,
  );

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

  loadedSlices.forEach(({ patchedSpec, behaviorModule }) => {
    // Typed core: builds the slice callback (functor), the JSON→command decode,
    // and the handleCommands invocation — all compiler-checked (was the fragile
    // positional call this file's line-146 comment warned about; see the
    // 2026-06-21 arity-drift incident referenced in the _Ops header).
    const jsonHandler = buildSliceHandler(
      patchedSpec,
      behaviorModule,
      tagKeysByEventType,
      crossPartitionTagKeys,
      sharedDcbEventLogOps,
    );
    for (const typeName of commandTypeNames(patchedSpec)) {
      handlersByType[typeName] = jsonHandler;
    }
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
  // outcome. Async: undefined → makeCommandGenerator falls back to publishJsons
  // and returns Pending. The schema is permissive (S.json) because AppSync has
  // already validated input against the SDL — per-slice schemas reapply inside
  // the typed core's buildSliceHandler decode.
  const publishJsonsAndWait = DISPATCH_MODE === "async"
    ? undefined
    : (jsons) => runInlineAndCollect(jsons, compositeJsonCommandsHandler);

  // Typed core (CommandGeneratorEntryPoint_Ops.res) pins the arg order against
  // the framework signature. stripIdFromParams=false: DCB slices may declare a
  // literal `id` field as part of the command schema (composite partition keys
  // etc.) — don't strip it.
  const generateCommand = makeCommandGenerator(
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
