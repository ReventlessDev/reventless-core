/**
 * Factory for reconstructing the Admin EventCollector handler chain in bundled
 * Lambda handlers.
 *
 * Handler chain (same as deploy-time):
 *   SQS event (subscribed to EP EventTopics)
 *   → EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(queue, handleEvents)
 *   → Admin_Callback.handleJsonEvents (forwards to EP outgoing handlers)
 *   → ExtensionPoint_Operations.Make(...).outgoingJsonEventsHandler
 *   → PluginExtensionPoint_Plugin mapping → publishToEventTopic / callHandler
 */

import { Effect } from "effect/Effect";
import { Stream } from "effect/Stream";
import { Make as PluginEPPluginMake } from "@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs";
import { Make as ExtensionPointOperationsMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res.mjs";
import * as PluginExtensionPointSpec from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import * as PluginReadModelSpec from "@reventlessdev/reventless-core/src/admin/PluginReadModelSpec.res.mjs";
import { handleDynamoDbOrSqsEvent } from "@reventlessdev/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res.mjs";
import { publish as snsPublish } from "@reventlessdev/reventless-aws/src/util/Util_SNS_Runtime.res.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs";
import {
  createSchedule as cwCreateSchedule,
  deleteSchedule as cwDeleteSchedule,
} from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";
import {
  val as shimVal,
  resource as shimResource,
} from "@reventlessdev/reventless-aws/src/util/Util_PulumiShim.res.mjs";
import {
  stitch,
  decode as decodeFragment,
} from "@reventlessdev/reventless-core/src/components/Api/GraphQL_Stitcher.res.mjs";
import { baseFragment as adminBaseFragment } from "@reventlessdev/reventless-core/src/admin/AdminApi.res.mjs";
import * as S from "sury/src/S.res.mjs";
import { patchSpecId, makeQueueRef, scanByTableName } from "./HandlerFactoryHelpers.mjs";

// AWS SDK — externalized by esbuild, available in Lambda runtime
import {
  AppSyncClient,
  StartSchemaCreationCommand,
} from "@aws-sdk/client-appsync";

let appSyncClient;
function getAppSyncClient() {
  if (!appSyncClient) appSyncClient = new AppSyncClient({});
  return appSyncClient;
}

/**
 * Inline @aws_auth injection (same as AppSync_Adapter.injectAwsAuthAll).
 * Avoids importing AppSync_Adapter which pulls in @pulumi/pulumi.
 */
function injectAwsAuthAll(fragment, group) {
  const parts = decodeFragment(fragment);
  const augmentedMutations = parts.mutations.map(
    (field) => `${field}\n    @aws_auth(cognito_groups: ["${group}"])`
  );
  const augmentedQueries = parts.queries.map(
    (field) => `${field} @aws_auth(cognito_groups: ["${group}"])`
  );
  const encoded = JSON.stringify({
    types: parts.types,
    mutations: augmentedMutations,
    queries: augmentedQueries,
  });
  return { encoded, protocol: "graphql" };
}

/**
 * Create the Admin EventCollector handler.
 *
 * @param {string} queueUrl - Admin EventCollector SQS queue URL (for message deletion)
 * @param {string} eventTopicArn - Plugin EP's EventTopic SNS ARN (for publishing outgoing events)
 * @param {string} pluginReadModelTableName - Plugin ReadModel DynamoDB table (for queryEngine)
 * @param {string} schedulerRoleArn - CloudWatch Events role ARN
 * @param {string} schedulerQueueArn - EP CommandTopic SQS queue ARN (scheduler target)
 * @param {string} schedulerQueueName - EP CommandTopic SQS queue name
 * @param {string} appSyncApiId - AppSync API ID (for schema updates on connect/disconnect)
 * @param {boolean} clonerEnabled - Whether cloner is enabled (affects admin base fragment)
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createAdminEventCollectorHandler({
  queueUrl,
  eventTopicArn,
  pluginReadModelTableName,
  schedulerRoleArn,
  schedulerQueueArn,
  schedulerQueueName,
  appSyncApiId,
  clonerEnabled,
}) {
  // --- Reconstruct runtimeOps for PluginExtensionPoint_Plugin ---
  const runtimeOps = {
    messagePublish: { sendMessageToChannel: sendMessage },
    topicSubscription: {
      subscribeChannelToTopic: async () => {},
      unsubscribeChannelFromTopic: async () => {},
    },
  };

  // --- Reconstruct updateApiSchema ---
  const updateApiSchema = appSyncApiId
    ? async (queryEngine) => {
        const plugins = await queryEngine.scan(
          "Plugin",
          [
            ["status", { TAG: "Contains" }, { TAG: "String", _0: "Connected" }],
          ],
          1000
        );
        const fragments = plugins
          .map((json) => {
            try {
              const state = S.parseOrThrow(json, PluginReadModelSpec.stateSchema);
              return state.apiSchemaFragment;
            } catch {
              return undefined;
            }
          })
          .filter(Boolean);
        const adminBase = injectAwsAuthAll(
          adminBaseFragment(clonerEnabled || false),
          "Admin"
        );
        const sdl = stitch(adminBase, fragments);
        await getAppSyncClient().send(
          new StartSchemaCreationCommand({
            apiId: appSyncApiId,
            definition: sdl,
          })
        );
      }
    : undefined;

  // --- Create Plugin EP mapping ---
  const pluginModule = PluginEPPluginMake({
    runtimeOps,
    environment: process.env.AWS_LAMBDA_FUNCTION_NAME || "unknown",
    updateApiSchema,
  });
  const mappingsModule = { mappings: [pluginModule.Mapping] };

  // --- Reconstruct SNS EventTopic publish ---
  const resolvedTopic = { name: eventTopicArn, id: eventTopicArn, arn: eventTopicArn };
  const publishToEventTopic = (id, meta, json) =>
    snsPublish(resolvedTopic, id, meta, json);

  // --- Reconstruct queryEngine ---
  const queryEngine = {
    scan: (readModelName, filterConfigs, limit) =>
      scanByTableName(pluginReadModelTableName, filterConfigs, limit),
    query: async () => {
      throw new Error("QueryEngine.query not available in bundled Admin EventCollector");
    },
  };

  // --- Reconstruct scheduler ---
  const fakeRole = { arn: shimVal(schedulerRoleArn || "NOT_AVAILABLE") };
  const scheduler = {
    createSchedule: cwCreateSchedule(fakeRole),
    deleteSchedule: cwDeleteSchedule,
  };

  const commandTopicResources = schedulerQueueArn
    ? [shimResource(schedulerQueueName, schedulerQueueArn)]
    : [];

  const invalidNameChars = /[^.\-_a-zA-Z0-9]/g;
  const resourceNaming = {
    validateName: (n) => n.replace(invalidNameChars, "_"),
    urnName: (arn) => (arn.split(":")[5] || "unknown"),
  };

  // --- Assemble EP outgoing event handler ---
  // Patch Id module alias — `module Id = Id.String` doesn't produce a runtime
  // value in ESM exports.
  const patchedSpec = patchSpecId(PluginExtensionPointSpec);
  const epOps = ExtensionPointOperationsMake(patchedSpec)(mappingsModule)({
    publishToEventTopic,
    commandTopicResources,
    scheduler,
    queryEngine,
    resourceNaming,
  });

  // --- Admin Callback: forward events to EP outgoing handlers ---
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

  const handleJsonEvents = (stream) =>
    Stream.runDrain(
      Stream.mapEffect(stream, (eventJson) =>
        Effect.flatMap(
          Effect.logInfo(
            `Admin handleJsonEvents: outgoing event: ${JSON.stringify(eventJson).substring(0, 200)}`
          ),
          () =>
            Effect.promise(async () => {
              await epOps.outgoingJsonEventsHandler(eventJson, fakePluginDefinition);
            })
        )
      )
    );

  // --- Wire up SQS handler ---
  return handleDynamoDbOrSqsEvent(makeQueueRef(queueUrl), handleJsonEvents);
}
