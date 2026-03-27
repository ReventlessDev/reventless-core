// Admin EventCollector Lambda entry point.
// All framework packages — no dynamic imports of user modules.
// Wires ExtensionPoint_Operations.Make for outgoing event handling,
// including API schema stitching on connect/disconnect events.

import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import { patchSpecId, makeQueueRef, scanByTableName } from "./HandlerFactoryHelpers.mjs";
import { val as shimVal, resource as shimResource } from "@reventlessdev/reventless-aws/src/util/Util_PulumiShim.res.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs";
import { publish as snsPublish } from "@reventlessdev/reventless-aws/src/util/Util_SNS_Runtime.res.mjs";
import PluginExtensionPointSpec from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import { Make as pluginEPPluginMake } from "@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs";
import { Make as extensionPointOperationsMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res.mjs";
import { handleDynamoDbOrSqsEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res.mjs";
import { createSchedule as cwCreateSchedule, deleteSchedule as cwDeleteSchedule } from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";
import { stitch as graphqlStitch, decode as decodeFragment } from "@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs";
import { baseFragment as adminBaseFragment } from "@reventlessdev/reventless-core/src/admin/AdminApi.res.mjs";
import { stateSchema as pluginReadModelStateSchema } from "@reventlessdev/reventless-core/src/admin/PluginReadModelSpec.res.mjs";
import { parseOrThrow as suryParseOrThrow } from "sury/src/S.res.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";

function injectAwsAuthAll(fragment, group) {
  const parts = decodeFragment(fragment);
  const augmentedMutations = parts.mutations.map(
    (field) => field + "\n    @aws_auth(cognito_groups: [\"" + group + "\"])"
  );
  const augmentedQueries = parts.queries.map(
    (field) => field + " @aws_auth(cognito_groups: [\"" + group + "\"])"
  );
  const encoded = JSON.stringify({
    types: parts.types,
    mutations: augmentedMutations,
    queries: augmentedQueries,
  });
  return { encoded, protocol: "graphql" };
}

async function updateAppSyncSchema(apiId, sdl) {
  const { AppSyncClient, StartSchemaCreationCommand } = await import("@aws-sdk/client-appsync");
  const client = new AppSyncClient({});
  await client.send(new StartSchemaCreationCommand({ apiId, definition: sdl }));
}

function runEffect(correlationId, effect) {
  return effect
    .pipe(Effect.provideService(requestContextTag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);
}

function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const runtimeOps = {
    messagePublish: { sendMessageToChannel: sendMessage },
    topicSubscription: {
      subscribeChannelToTopic: async () => {},
      unsubscribeChannelFromTopic: async () => {},
    },
  };

  const lambdaFunctionName = process.env["AWS_LAMBDA_FUNCTION_NAME"] || "unknown";

  function mkUpdateApiSchema(tableName, apiId, clonerEnabled) {
    if (!apiId || apiId === "NOT_AVAILABLE") return undefined;
    return async (queryEngine) => {
      const plugins = queryEngine.scan(
        "Plugin",
        [["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }]],
        1000
      );
      const resolved = await plugins;
      const fragments = resolved
        .map((json) => {
          try {
            const state = suryParseOrThrow(json, pluginReadModelStateSchema);
            return state.apiSchemaFragment;
          } catch (_) { return undefined; }
        })
        .filter(Boolean);
      const adminBase = injectAwsAuthAll(
        adminBaseFragment(clonerEnabled || false),
        "Admin"
      );
      const sdl = graphqlStitch(adminBase, fragments);
      await updateAppSyncSchema(apiId, sdl);
    };
  }

  const updateApiSchemaFn = mkUpdateApiSchema(
    config.pluginReadModelTableName,
    config.appSyncApiId,
    config.clonerEnabled
  );

  const pluginModule = pluginEPPluginMake({
    runtimeOps,
    environment: lambdaFunctionName,
    updateApiSchema: updateApiSchemaFn,
  });

  const mappingsModule = { mappings: [pluginModule.Mapping] };

  const resolvedTopic = {
    name: config.eventTopicArn,
    id: config.eventTopicArn,
    arn: config.eventTopicArn,
  };
  const publishToEventTopic = (id, meta, json) => snsPublish(resolvedTopic, id, meta, json);

  const queryEngine = {
    scan: (readModelName, filterConfigs, limit) => scanByTableName(config.pluginReadModelTableName, filterConfigs, limit),
    query: async () => { throw new Error("QueryEngine.query not available in bundled Admin EventCollector"); },
  };

  const fakeRole = shimVal(config.schedulerRoleArn);
  const scheduler = {
    createSchedule: cwCreateSchedule({ arn: fakeRole }),
    deleteSchedule: cwDeleteSchedule,
  };

  const commandTopicResources = config.schedulerQueueArn !== ""
    ? [shimResource(config.schedulerQueueName, config.schedulerQueueArn)]
    : [];

  const invalidNameChars = /[^.\-_a-zA-Z0-9]/g;
  const resourceNaming = {
    validateName: (n) => n.replace(invalidNameChars, "_"),
    urnName: (arn) => { const parts = arn.split(":"); return parts[5] || "unknown"; },
  };

  const patchedSpec = patchSpecId(PluginExtensionPointSpec);
  const epOps = extensionPointOperationsMake(patchedSpec)(mappingsModule)({
    publishToEventTopic,
    commandTopicResources,
    scheduler,
    queryEngine,
    resourceNaming,
  });

  const fakePluginDefinition = {
    id: "Admin@INTERNAL",
    name: "Admin",
    version: "INTERNAL",
    extensionPoints: [],
    extensions: [],
    eventCollector: "NOT-SET",
    extensionProtocols: [],
    apiSchemaFragment: undefined,
  };

  const handleJsonEvents = stream => Stream.runDrain(
    Stream.mapEffect(stream, eventJson =>
      Effect.flatMap(
        Effect.logInfo("Admin handleJsonEvents: outgoing event: " + JSON.stringify(eventJson).substring(0, 200)),
        _ => Effect.promise(async () => await epOps.outgoingJsonEventsHandler(eventJson, fakePluginDefinition))
      )
    )
  );

  return handleDynamoDbOrSqsEvent(makeQueueRef(config.queueUrl), handleJsonEvents);
}

const sqsHandler = buildHandler();

export async function handler(event, context) {
  const records = event.Records || [];
  console.log("----- adminEventCollectorHandler: processing " + records.length.toString() + " record(s)");
  await runEffect(undefined, sqsHandler(event, context));
  return "";
}
