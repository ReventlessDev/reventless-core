// Plugin EventCollector Lambda entry point — shared between the platform and every
// per-plugin EventCollector Lambda. This module is plugin-agnostic: behaviour is
// driven entirely by HANDLER_CONFIG.
//
// Thin untyped shell ("typed core, thin shell" —
// docs/plans/minimize-lambda-entrypoint-mjs-shell.md): this file owns ONLY the
// seams that are inherently untyped — the dynamic `import()` of EP/extension/spec
// modules named in HANDLER_CONFIG and the functor applications consuming those
// runtime-loaded modules. Everything else (config parse/validation, the Plugin-RM
// projection, the cross-plugin SNS subscription manager, publish/query/scheduler
// operations, handler-dict assembly, Plugin_Callback wiring, dispatch boundary)
// lives type-checked in EventCollectorEntryPoint_Ops.res.
//
// HANDLER_CONFIG schema (JSON in env var "HANDLER_CONFIG"):
//
// {
//   "queueUrl":                       string  // SQS URL of the EventCollector this Lambda drains
//   "pluginExtensionPointCmdTopicUrl":string  // SQS URL of PlatformPluginExtPoint cmd topic (admin's Plugin EP)
//   "eventTopicArn":                  string  // SNS ARN the EP's outgoing events publish to ("NOT_AVAILABLE" if none)
//   "pluginReadModelTableName":       string  // DynamoDB table for Plugin RM (used by QueryEngine.scan)
//   "appSyncApiId":                   string  // "NOT_AVAILABLE" disables schema stitching
//   "schedulerRoleArn":               string  // IAM role for CloudWatch Events schedule targets
//   "schedulerQueueArn":              string  // ARN of the cmd topic the scheduler publishes to ("" → no commandTopicResources)
//   "schedulerQueueName":             string
//   "extensionPoints": [                       // EPs whose OUTGOING events this Lambda processes; admin: 1 entry, plugins: []
//     {
//       "specModule":      string,   // dynamic import specifier for the EP spec module
//       "mappingsModule":  string,   // dynamic import specifier for the EP mapping factory (exports `Make`)
//       "eventTopicArn":   string,   // SNS ARN the EP's outgoing events publish to (per-EP override of top-level eventTopicArn)
//       "aggregateNames":  string[]  // delegate aggregate names — service keys for outgoingExtensionPointEventHandlers
//     }
//   ],
//   "connectExtension": {                      // The auto-included PluginConnectExtension entry; null for admin Lambda
//     "specModule":         string,
//     "mappingsModule":     string,
//     "extensionPointName": string             // service key for incomingConnectExtensionEventHandlers (e.g. "Platform.Plugin")
//   } | null,
//   "extensions": [                            // User-declared extensions — wired into incoming/outgoing dicts at cold start
//     {
//       "name":               string,          // extension component name (used for logs / dedupe)
//       "specModule":         string,          // dynamic import for the ExtensionPoint spec module
//       "mappingsModule":     string,          // dynamic import for the user extension file (`module Mapping`)
//       "delegateModule":     string,          // dynamic import for the Delegate spec (aggregate / slice)
//       "extensionPointName": string,          // service key for incomingExtensionEventHandlers (e.g. "Ordering.Orders")
//       "aggregateNames":     string[],        // outgoing service keys + filter into top-level publishToAggregates
//       "readModelNames":     string[]         // RMs this extension may enqueue events into (filter into readModelQueueUrls)
//     }
//   ],
//   "publishToAggregates": {                   // aggregateName → env-var name holding the aggregate's cmd-topic SQS URL
//     "Plugin": "PTA_Plugin_QUEUE_URL"
//   },
//   "readModelQueueUrls": {                    // rmName → env-var name holding the RM's EventCollector SQS URL
//     "ProductDemands": "PRM_ProductDemands_QUEUE_URL"
//   },
//   "readModelNamesForSourceName": {           // deploy-side inversion of RM.sourceNames; sourceServiceName → [rmName]
//     "Ordering.Orders": ["ProductDemands"]
//   }
// }
//
// Why this shape and not separate entry points per Lambda: at deploy time both the
// admin EventCollector and every per-plugin EventCollector share the same code
// asset (this file). The runtime differences are entirely data — which EPs to
// process outgoing events for (admin only) and which Connect extension to wire
// (plugin only). Plugin_Callback.Make routes incoming SQS events to the right
// service-keyed handler dict; Ops reconstructs those dicts from what we wire here.

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { patchSpecId } from "./HandlerFactoryHelpers.mjs";
import { Make as extensionPointOperationsMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res.mjs";
import { Make as extensionOperationsMake } from "@reventlessdev/reventless-core/src/components/Extension/Extension_Operations.res.mjs";
import { Make as extensionMappingMake } from "@reventlessdev/reventless-infra/src/types/ExtensionMapping.res.mjs";
import { Make as extensionPointMappingMake } from "@reventlessdev/reventless-infra/src/types/ExtensionPointMapping.res.mjs";
import * as Ops from "./EventCollectorEntryPoint_Ops.res.mjs";

// Cross-plugin spec packages (e.g. "@reventlessdev/online-shop-hybrid-catalog-spec")
// are bundled into the function asset under /var/task/node_modules/ by
// PluginRuntime_Builder.forPluginEventCollector. This entry-point file, however,
// lives in the Lambda LAYER at /opt/nodejs/node_modules/.../EventCollectorEntryPoint.mjs,
// so a bare `await import("@reventlessdev/online-shop-hybrid-catalog-spec/...")`
// from here resolves through /opt/nodejs/node_modules/ and never reaches the
// function asset. Anchoring createRequire at file:///var/task/index.mjs makes
// resolution walk /var/task/node_modules first (and NODE_PATH-listed dirs as
// fallback, which Lambda sets to /opt/nodejs/node_modules — so static-import
// targets like reventless-core still resolve too). We then turn the resolved
// filesystem path into a file:// URL and dynamic-import it.
const importFromAsset = (() => {
  const requireFromAsset = createRequire(`file://${process.cwd()}/index.mjs`);
  return async (specifier) => {
    const resolved = requireFromAsset.resolve(specifier);
    return import(pathToFileURL(resolved).href);
  };
})();

async function buildHandler() {
  const config = Ops.parseHandlerConfig(process.env["HANDLER_CONFIG"] || "");
  const pluginDefinition = Ops.loadPluginDefinition();

  const queryEngine = Ops.makeQueryEngine(config.pluginReadModelTableName);
  const scheduler = Ops.makeScheduler(config.schedulerRoleArn);
  const commandTopicResources = Ops.makeCommandTopicResources(config);
  const manageSubscriptionsFn = Ops.makeManageSubscriptions(config.pluginReadModelTableName);

  // EP operations — admin has 1 entry (Plugin EP), plugins have N user EPs.
  //
  // Two mapping shapes flow through `config.extensionPoints`:
  //
  //   1. Admin-internal (PluginExtensionPoint_Plugin.res.mjs) — exports a
  //      `Make(Spec)` functor consuming runtime ops. Used only by the admin
  //      Lambda's Plugin EP. Returns `{Mapping}`.
  //
  //   2. User-authored (e.g. Products_ExtensionPointMapping.res.mjs) — exports
  //      the Mapping fields at top level (mapIncomingCommand, mapOutgoingEvent,
  //      Delegate, ...) with NO `Make` functor. Used by every plugin EC Lambda
  //      that declares an ExtensionPoint. The ExtensionPoint spec module is
  //      erased at compile time and must be re-attached at runtime.
  //
  // Dispatch on `typeof Make === function` to handle both.
  const epHandlers = await Promise.all(config.extensionPoints.map(async (ep) => {
    const specMod = patchSpecId(await importFromAsset(ep.specModule));
    const mappingsMod = await importFromAsset(ep.mappingsModule);

    let mappingsModule;
    if (typeof mappingsMod.Make === "function") {
      // Admin's Plugin EP: invoke the Make functor with runtime ops.
      const epModule = mappingsMod.Make({
        runtimeOps: Ops.runtimeOps,
        environment: Ops.environment,
        // Connect-driven schema self-heal retired — the ApiSchemaPush
        // SideEffect on ApiFragmentRegistry events is the single schema writer.
        updateApiSchema: undefined,
        manageSubscriptions: Ops.manageForDefinition(manageSubscriptionsFn),
      });
      mappingsModule = { mappings: [epModule.Mapping] };
    } else {
      // User EP: reconstruct MappingImpl from top-level exports, re-attach
      // the erased ExtensionPoint spec module, then transform input shape
      // (mapIncomingCommand/mapOutgoingEvent) into the runtime T shape via
      // ExtensionPointMapping.Make. `Delegate.Id` is also patched via
      // patchSpecId — the inner `module Delegate = { module Id = Id.String; … }`
      // is erased at compile time the same way the top-level `module Id` is,
      // and ExtensionPointMapping.Make reads `Delegate.Id.schema` at runtime to
      // decode incoming events.
      const mappingImpl = {
        ...mappingsMod,
        ExtensionPoint: specMod,
        Delegate: patchSpecId(mappingsMod.Delegate),
        moduleUrl: ep.mappingsModule,
      };
      mappingsModule = { mappings: [extensionPointMappingMake(mappingImpl)] };
    }

    const ops = extensionPointOperationsMake(specMod)(mappingsModule)({
      publishToEventTopic: Ops.makePublishToEventTopic(ep.eventTopicArn),
      commandTopicResources,
      scheduler,
      queryEngine,
      resourceNaming: Ops.resourceNaming,
    });
    return { aggregateNames: ep.aggregateNames, outgoingHandler: ops.outgoingJsonEventsHandler };
  }));

  const publishToAggregates = Ops.buildPublishToAggregates(config.publishToAggregates);
  const publishToPluginExtensionPoint = Ops.makePublishJsons(config.pluginExtensionPointCmdTopicUrl);

  // Connect extension — exactly one entry per plugin Lambda; null for admin.
  let connectExtensionHandler = undefined;
  if (config.connectExtension) {
    const ext = config.connectExtension;
    const specMod = patchSpecId(await importFromAsset(ext.specModule));
    const mappingsMod = await importFromAsset(ext.mappingsModule);
    // The Connect extension Spec carries pluginDefinition plus the plugin's
    // UI-fragment manifest (its own asset). loadUiFragments returns a ReScript
    // option — `undefined` (None) for plugins without a UI.
    const extBuilder = mappingsMod.Make({
      pluginDefinition,
      uiFragments: Ops.loadUiFragments(),
    });
    // PluginConnectExtension_Builder.Make returns a module exposing:
    //   - ConnectPluginMapping  (single mapping)
    //   - ConnectPluginMappings (Mappings module: {Spec, name, mappings, moduleUrl})
    // Use ConnectPluginMappings as the Mappings arg to Extension_Operations.Make.
    const ops = extensionOperationsMake(specMod)(extBuilder.ConnectPluginMappings)({
      publishToAggregates,
      publishToPluginExtensionPoint,
      readModelNamesForSourceName: {},
      publishToReadModels: {},
      queryEngine,
    });
    connectExtensionHandler = {
      extensionPointName: ext.extensionPointName,
      incomingHandler: ops.incomingJsonEventsHandler,
    };
  }

  // User-declared extensions — per-entry: three dynamic imports (EP spec,
  // user mapping file, Delegate spec), reconstruct the full Mapping object
  // (compiled .res.mjs erases Mapping.ExtensionPoint / Mapping.Delegate), run
  // it through ExtensionMapping.Make, and build per-extension Extension_Operations.
  const userExtensionHandlers = await Promise.all(config.extensions.map(async (ext) => {
    if (!ext.specModule || !ext.mappingsModule || !ext.delegateModule) {
      Ops.warnSkippedExtension(ext);
      return null;
    }
    const epSpec = patchSpecId(await importFromAsset(ext.specModule));
    const userMod = await importFromAsset(ext.mappingsModule);
    const delegateSpec = patchSpecId(await importFromAsset(ext.delegateModule));

    // Reconstruct Mapping with the freshly imported specs re-attached. The
    // moduleUrl / delegateModuleUrl fields satisfy the ExtensionMapping.Mapping
    // module type — ExtensionMapping.Make doesn't currently consume them at
    // runtime, but we set them for shape parity.
    const fullMapping = {
      ExtensionPoint: epSpec,
      Delegate: delegateSpec,
      moduleUrl: ext.mappingsModule,
      delegateModuleUrl: ext.delegateModule,
      mapIncomingEvent: userMod.Mapping.mapIncomingEvent,
      mapOutgoingEvent: userMod.Mapping.mapOutgoingEvent,
    };
    const transformedMapping = extensionMappingMake(fullMapping);
    const mappingsModule = {
      name: ext.name,
      moduleUrl: ext.mappingsModule,
      mappings: [transformedMapping],
    };

    const dicts = Ops.extensionPublishDicts(config, ext);
    const ops = extensionOperationsMake(epSpec)(mappingsModule)({
      publishToAggregates: dicts.publishToAggregates,
      publishToPluginExtensionPoint,
      readModelNamesForSourceName: dicts.readModelNamesForSourceName,
      publishToReadModels: dicts.publishToReadModels,
      queryEngine,
    });

    return {
      extensionPointName: ext.extensionPointName,
      aggregateNames: ext.aggregateNames,
      incomingHandler: ops.incomingJsonEventsHandler,
      outgoingHandler: ops.outgoingJsonEventsHandler,
    };
  }));

  // Cold-start reconciliation — awaited so it finishes inside the same
  // invocation that initialised the Lambda (a floating promise pauses when the
  // runtime freezes between invocations). Idempotent at the SNS level.
  await Ops.reconcileSubscriptionsOnce(config.pluginReadModelTableName, manageSubscriptionsFn);

  return Ops.makeSqsHandlerBundle({
    pluginDefinition,
    queueUrl: config.queueUrl,
    epHandlers,
    connectExtensionHandler,
    extensionHandlers: userExtensionHandlers.filter(Boolean),
  });
}

export const handler = Ops.makeHandler(buildHandler());
