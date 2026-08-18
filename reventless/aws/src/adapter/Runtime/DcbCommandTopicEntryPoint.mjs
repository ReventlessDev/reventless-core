// DcbCommandTopic Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports StateChangeSlice modules,
// builds shared DcbEventLog operations and per-slice handlers keyed by command type name.
// Dual routing: AppSync direct invocation and SQS CommandTopic events.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as Chunk from "effect/Chunk";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import {
  patchSpecId,
  makeQueueRef,
  log,
  runEffect,
  setRequestId,
  extractMetaField,
  extractSentTimestamp,
  extractRetryCount,
  runtimeExtensionsReady,
} from "./HandlerFactoryHelpers.mjs";
import { Make as dcbEventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/DcbEventLog/DcbEventLog_Operations.res.mjs";
import { makeCommandGenerator } from "./CommandGeneratorEntryPoint_Ops.res.mjs";
import { commandOutcomeToJson, runInlineAndCollect } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res.mjs";
// `json` lives on sury's own entry, not the ReScript shim — `S.res.mjs` stopped
// re-exporting it in sury 11. This is the same binding the compiled ReScript uses.
import { json as jsonSchema } from "sury";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
// Typed cold-start core — scope/partitionTag derivation, storage-ops wiring, and
// per-slice handler building (functor + decode + handleCommands), all
// compiler-checked against the framework signatures (see the module header and
// docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md).
import { deriveScope, commandTypeNames, makeStorageOps, buildSliceHandler, buildInboundReceiver } from "./DcbCommandTopicEntryPoint_Ops.res.mjs";
import { makeDynamoQueryDbOps } from "./QueryDbEntryPoint_Ops.res.mjs";

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

// This Lambda hosts one plugin's StateChangeSlices behind a composite handler
// that routes per command TAG *inside* the stream — so the dispatch boundary
// names the runtime group, not the individual slice. `Kind(Name)` matches the
// shape every other comp uses, and the plugin name resolves through
// LogPrefix.
const dcbComp = (plugin) => `DcbCommandTopicRuntime(${plugin})`;

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
  const commandSchemasByType = {};
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
      // The schema this command's owner fields are read from. Kept beside the
      // handler because the two answer the same question — "which slice is this
      // command?" — and a command routed to a handler but not to a schema is
      // exactly the state that stamps nothing while looking like it worked.
      if (commandSchemasByType[typeName] !== undefined) {
        log.error(
          "two DCB slices declare the command \"" + typeName + "\"; owner stamping " +
            "resolves a command by that name alone and cannot tell them apart",
          { comp: "DcbCommandTopicRuntime" },
        );
      } else {
        commandSchemasByType[typeName] = patchedSpec.commandSchema;
      }
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

  // Route 0 registry: InboundTranslationSlice receive handlers keyed by their
  // AppSync mutation field name. The resolver invokes this Lambda with
  // {__inboundTranslation, fieldName, arguments}; the field name is
  // `<pluginName>_<sliceName>` (Api_Naming.sliceMutationField — the deploy side
  // uses the same `name` that HANDLER_CONFIG.pluginName carries). The spec +
  // translation modules are the one untyped seam (dynamic import); the typed
  // `buildInboundReceiver` owns the functor call + audit persistence. Audit ops
  // are DynamoDB-only for now (makeDynamoQueryDbOps); Postgres audit is a
  // follow-up, so on that backend the receiver runs without persistence.
  const inboundModules = config.inboundTranslationSliceModules || [];
  const inboundReceiversByField = {};
  await Promise.all(inboundModules.map(async ({ spec, translation, auditTableName }) => {
    const specModule = await loadModule(spec);
    const translationModule = await loadModule(translation);
    // auditTableName must be a real non-empty string. A non-string here (e.g. a
    // mis-serialized deploy-time value) would build a QueryDb ops whose TableName
    // is an object, and every PutCommand would crash in AWS endpoint resolution
    // ("value.split is not a function") — silently, since the audit save is
    // best-effort. Guard against that instead of trusting the config shape.
    const hasAuditTable = typeof auditTableName === "string" && auditTableName.length > 0;
    if (auditTableName != null && !hasAuditTable) {
      log.warn(
        "inbound audit table name is not a string; skipping audit persistence: " +
          JSON.stringify(auditTableName),
        { comp: "DcbCommandTopicRuntime" },
      );
    }
    const auditOps = (hasAuditTable && !config.pgConnection)
      ? makeDynamoQueryDbOps(auditTableName)
      : undefined;
    const fieldName = config.pluginName + "_" + specModule.name;
    inboundReceiversByField[fieldName] = buildInboundReceiver(
      specModule,
      translationModule,
      publishJsons,
      auditOps,
    );
  }));

  // Sync (default): inline-dispatch the command via the same composite handler
  // that Route 2 uses, so the AppSync resolver gets a typed Accepted/Rejected
  // outcome. Async: undefined → makeCommandGenerator falls back to publishJsons
  // and returns Pending.
  const publishJsonsAndWait = DISPATCH_MODE === "async"
    ? undefined
    : (jsons) => runInlineAndCollect(jsons, compositeJsonCommandsHandler);

  // Typed core (CommandGeneratorEntryPoint_Ops.res) pins the arg order against
  // the framework signature. stripIdFromParams=false: DCB slices may declare a
  // literal `id` field as part of the command schema (composite partition keys
  // etc.) — don't strip it.
  //
  // One generator per command, differing only in the schema. This used to be a
  // single generator built on the permissive `jsonSchema`, on the still-true
  // grounds that AppSync has already validated input against the SDL and that
  // per-slice schemas reapply inside `buildSliceHandler`'s decode. What that
  // reasoning did not cover is that the schema is also where `makeGenerateCommand`
  // reads a command's `@owner` fields from: given `S.json` it finds none, for every
  // command, and the write keeps whatever owner the CLIENT sent. Validation was
  // never the only job.
  const makeGeneratorFor = (commandSchema) => makeCommandGenerator(
    publishJsons,
    publishJsonsAndWait,
    config.pluginName,
    commandSchema,
    "StateChangeSlice",
    false,
  );
  const generatorsByType = {};
  for (const typeName of Object.keys(commandSchemasByType)) {
    generatorsByType[typeName] = makeGeneratorFor(commandSchemasByType[typeName]);
  }
  // A command no loaded slice claims keeps the permissive generator — what every
  // command got before this change — so anything reaching this handler by another
  // route behaves as it did. It also cannot stamp, hence the warning.
  const generateFallback = makeGeneratorFor(jsonSchema);

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
    let generateCommand = generatorsByType[event.command];
    if (generateCommand === undefined) {
      log.warn(
        "no DCB slice declares the command \"" + event.command + "\"; dispatching " +
          "without an owner stamp, so any @owner field keeps the value the caller sent",
        { comp: "DcbCommandTopicRuntime" },
      );
      generateCommand = generateFallback;
    }
    return generateCommand({ ...event, meta, identity });
  };

  // Elements past the first two are additive — existing callers (the integration
  // tests) keep destructuring the first two. No deploy-time `plugin` fragment
  // needed here: this Lambda serves exactly one plugin and HANDLER_CONFIG already
  // names it. The 5th element is the Route 0 inbound-translation registry.
  return [sqsHandler, cmdGenHandler, dcbComp(config.pluginName), config.pluginName, inboundReceiversByField];
}

async function buildHandler() {
  // Runtime extension seam: any registered out-of-tree extension gets its
  // onColdStart before a single handler is built, which is what makes the
  // framework's interception/publish hooks reachable here. No-op unless the
  // deployment registered one.
  await runtimeExtensionsReady;
  const configStr = process.env["HANDLER_CONFIG"];
  // Importing this module without HANDLER_CONFIG (e.g. from a test that drives
  // `buildHandlersForConfig` directly) must not crash module evaluation.
  // Lambda always sets HANDLER_CONFIG; the production path is unchanged.
  if (!configStr) return [null, null, undefined, undefined];
  const config = JSON.parse(configStr);
  // The slice registry rides in the archive, not the environment — two module
  // specifiers per slice outgrow Lambda's 4KB env-var ceiling (see the asset in
  // StateChangeSliceRuntime_Builder_Single). An inline registry still wins, so a
  // caller that supplies one — every test that drives a config directly — needs
  // no asset on disk. process.cwd() is /var/task, where the archive unpacks.
  if (config.stateChangeSliceModules === undefined) {
    config.stateChangeSliceModules = JSON.parse(
      readFileSync(join(process.cwd(), "sliceModules.json"), "utf-8"),
    );
  }
  return buildHandlersForConfig(config, { loadModule: dynamicImport });
}

const initPromise = buildHandler();

export async function handler(event, context) {
  setRequestId(context?.awsRequestId);
  const [sqsHandler, cmdGenHandler, comp, plugin, inboundReceivers] = await initPromise;

  // Route 0: InboundTranslationSlice mutation — the AppSync resolver invokes this
  // Lambda with `{__inboundTranslation: true, fieldName, arguments}` (no `command`,
  // no `Records`). Dispatch to the field's receive handler, which translates +
  // publishes and returns a commandOutcome JSON byte-compatible with Route 1's
  // `commandOutcomeToJson`. Without this branch the payload fell through to Route 2
  // and crashed on `event.records` being undefined.
  if (event.__inboundTranslation === true) {
    const fieldName = event.fieldName;
    const receiver = (inboundReceivers || {})[fieldName];
    if (receiver === undefined) {
      log.warn("no inbound translation receiver for field: " + fieldName, { comp: "DcbCommandTopicRuntime" });
      throw new Error("no inbound translation receiver for field: " + fieldName);
    }
    log.debug("InboundTranslation invocation (" + fieldName + ")", { comp: "DcbCommandTopicRuntime" });
    return await receiver(event.arguments);
  }

  // Route 1: AppSync direct invocation — payload carries the CommandGenerator.payload
  // shape (`{command, arguments, meta, identity?}`).
  if (event.command != null && event.arguments != null) {
    log.debug("AppSync direct invocation (" + DISPATCH_MODE + ")", { comp: "DcbCommandTopicRuntime" });
    // Direct invoke: the envelope is on `event.meta`, and there is no send time
    // or receive count on this path.
    const outcome = await runEffect(cmdGenHandler(event), {
      correlationId: event.meta?.correlationId,
      causationId: event.meta?.causationId,
      comp,
      plugin,
    });
    return commandOutcomeToJson(outcome);
  }

  // Route 2: SQS CommandTopic events
  const records = event.Records || [];
  log.debug("processing " + records.length.toString() + " record(s)", { comp: "DcbCommandTopicRuntime" });
  await runEffect(sqsHandler(event, context), {
    correlationId: extractMetaField(records, "correlationId"),
    causationId: extractMetaField(records, "causationId"),
    comp,
    plugin,
    timestamp: extractSentTimestamp(records),
    retryCount: extractRetryCount(records),
  });
  return "";
}
