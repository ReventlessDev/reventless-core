/**
 * Factory for reconstructing the Plugin ExtensionPoint handler chain in bundled
 * Lambda handlers.
 *
 * Unlike the generic BundledExtensionPointHandlerFactory which stubs queryEngine
 * and scheduler, this factory reconstructs working versions using AWS SDK calls
 * directly. It also instantiates the PluginExtensionPoint_Plugin mapping with
 * reconstructed runtimeOps (SQS message forwarding).
 *
 * Handler chain (same as deploy-time):
 *   SQS event (CommandTopic)
 *   → CommandTopicChannel_SQS_Runtime.handleQueueEvent(queue, handleJsonCommands)
 *   → CommandTopic_Callback.Make(Spec)(Ops).handleJsonCommands
 *   → ExtensionPoint_Callback.Make(Config)(Spec)(Mappings).handleIncomingCommands
 *   → PluginExtensionPoint_Plugin mapping → publishToAggregates / callHandler
 */

import { Make as PluginEPPluginMake } from "@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs";
import * as PluginExtensionPointSpec from "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs";
import { Make as ExtensionPointCallbackMake } from "@reventlessdev/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res.mjs";
import { Make as CommandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import {
  handleQueueEvent,
  publishJsons as makePublishJsons,
} from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_PluginMessage_Runtime.res.mjs";
import {
  createSchedule as cwCreateSchedule,
  deleteSchedule as cwDeleteSchedule,
} from "@reventlessdev/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res.mjs";
import {
  val as shimVal,
  resource as shimResource,
} from "@reventlessdev/reventless-aws/src/util/Util_PulumiShim.res.mjs";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";

// AWS SDK — externalized by esbuild, available in Lambda runtime
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";

const ddbClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));

/**
 * Inline DynamoDB scan — avoids importing QueryEngine_DynamoDb which pulls
 * in @pulumi/pulumi via its `make` function.
 *
 * Replicates QueryEngine_DynamoDb.scanByTableName for the subset needed by
 * the Plugin EP mapping (scan with Contains/Equal filter comparators).
 */
async function scanByTableName(tableName, filterConfigs, limit) {
  const filterParts = [];
  const attrNames = {};
  const attrValues = {};

  (filterConfigs || []).forEach(([fieldName, comparator, value], idx) => {
    const valueName = `${fieldName}${idx}`;
    attrNames[`#${fieldName}`] = fieldName;

    // Extract the actual value from the tagged union
    let attrValue;
    if (typeof value === "object" && value !== null && "TAG" in value) {
      // ReScript tagged variant: String("x") → { TAG: "String", _0: "x" }
      attrValue = value._0;
    } else {
      attrValue = value;
    }
    attrValues[`:${valueName}`] = attrValue;

    // Comparator is a ReScript variant — match the TAG
    const comp =
      typeof comparator === "object" ? comparator.TAG || comparator : comparator;
    switch (comp) {
      case "Equal":
        filterParts.push(`#${fieldName} = :${valueName}`);
        break;
      case "Unequal":
        filterParts.push(`#${fieldName} <> :${valueName}`);
        break;
      case "Contains":
        filterParts.push(`contains( #${fieldName}, :${valueName} )`);
        break;
      case "NotContains":
        filterParts.push(`NOT contains( #${fieldName}, :${valueName} )`);
        break;
      case "BeginsWith":
        filterParts.push(`begins_with( #${fieldName}, :${valueName} )`);
        break;
      case "Exists":
        filterParts.push(`attribute_exists( #${fieldName} )`);
        break;
      case "NotExists":
        filterParts.push(`attribute_not_exists( #${fieldName} )`);
        break;
      case "LessOrEqual":
        filterParts.push(`#${fieldName} <= :${valueName}`);
        break;
      case "Less":
        filterParts.push(`#${fieldName} < :${valueName}`);
        break;
      case "GreaterOrEqual":
        filterParts.push(`#${fieldName} >= :${valueName}`);
        break;
      case "Greater":
        filterParts.push(`#${fieldName} > :${valueName}`);
        break;
      default:
        filterParts.push(`#${fieldName} = :${valueName}`);
    }
  });

  const params = {
    TableName: tableName,
    Limit: limit,
  };
  if (filterParts.length > 0) {
    params.FilterExpression = filterParts.join(" AND ");
    params.ExpressionAttributeNames = attrNames;
    params.ExpressionAttributeValues = attrValues;
  }

  const items = [];
  let lastKey;
  do {
    if (lastKey) params.ExclusiveStartKey = lastKey;
    const result = await ddbClient.send(new ScanCommand(params));
    if (result.Items) items.push(...result.Items);
    lastKey = result.LastEvaluatedKey;
  } while (lastKey && items.length < limit);

  return items;
}

/**
 * Create the Plugin ExtensionPoint CommandTopic handler.
 *
 * @param {Object} publishToAggregatesEnv - Map of aggregate name → SQS FIFO queue URL
 * @param {string} queueUrl - EP's own CommandTopic SQS queue URL (for message deletion)
 * @param {string} pluginReadModelTableName - DynamoDB table for Plugin read model (queryEngine)
 * @param {string} schedulerRoleArn - IAM role ARN for CloudWatch Events scheduler
 * @param {string} schedulerQueueArn - SQS queue ARN for scheduled event targets
 * @param {string} schedulerQueueName - SQS queue name for scheduled event targets
 * @returns {Function} Effect handler: (event, context) => Effect.t<unit, string, unit>
 */
export function createPluginExtensionPointHandler({
  publishToAggregatesEnv,
  queueUrl,
  pluginReadModelTableName,
  schedulerRoleArn,
  schedulerQueueArn,
  schedulerQueueName,
}) {
  // PluginExtensionPointSpec always uses Id.String, but `module Id = Id.String`
  // doesn't produce a runtime value in ESM. Use IdString directly to avoid
  // esbuild "import is undefined" warning.
  const patchedSpec = {
    ...PluginExtensionPointSpec,
    Id: IdString,
  };

  // --- Reconstruct runtimeOps ---
  const runtimeOps = {
    messagePublish: {
      sendMessageToChannel: sendMessage,
    },
    topicSubscription: {
      subscribeChannelToTopic: async () => {},
      unsubscribeChannelFromTopic: async () => {},
    },
  };

  // --- Instantiate Plugin EP mapping ---
  const pluginModule = PluginEPPluginMake({
    runtimeOps,
    environment: process.env.AWS_LAMBDA_FUNCTION_NAME || "unknown",
    // updateApiSchema is only used in the outgoing event path (EventCollector),
    // not in the incoming command path (CommandTopic handler).
    updateApiSchema: undefined,
  });
  const mappingsModule = { mappings: [pluginModule.Mapping] };

  // --- Reconstruct publishToAggregates ---
  const publishToAggregates = {};
  for (const [aggName, aggQueueUrl] of Object.entries(
    publishToAggregatesEnv || {}
  )) {
    const queue = { id: aggQueueUrl, name: aggQueueUrl, arn: "" };
    publishToAggregates[aggName] = makePublishJsons(queue, "SQS_FIFO");
  }

  // --- Reconstruct queryEngine ---
  const queryEngine = {
    scan: (readModelName, filterConfigs, limit) =>
      scanByTableName(pluginReadModelTableName, filterConfigs, limit),
    query: async () => {
      throw new Error(
        "QueryEngine.query not available in bundled Plugin EP handler"
      );
    },
  };

  // --- Reconstruct scheduler ---
  // createSchedule expects role.arn.get() — use PulumiShim.val to wrap the ARN
  const fakeRole = { arn: shimVal(schedulerRoleArn) };
  const scheduler = {
    createSchedule: cwCreateSchedule(fakeRole),
    deleteSchedule: cwDeleteSchedule,
  };

  // --- Reconstruct commandTopicResources ---
  // Used by ScheduleOps for PutTargets — the SQS queue that scheduled events target
  const commandTopicResources = schedulerQueueArn
    ? [shimResource(schedulerQueueName, schedulerQueueArn)]
    : [];

  // --- ResourceNaming ---
  const invalidNameChars = /[^.\-_a-zA-Z0-9]/g;
  const resourceNaming = {
    validateName: (n) => n.replace(invalidNameChars, "_"),
    urnName: (arn) => {
      const parts = arn.split(":");
      return parts[5] || "unknown";
    },
  };

  // --- Assemble handler chain ---
  const callbackConfig = {
    publishToAggregates,
    commandTopicResources,
    scheduler,
    queryEngine,
    resourceNaming,
  };
  const callback = ExtensionPointCallbackMake(callbackConfig)(patchedSpec)(
    mappingsModule
  );

  const commandTopicCallback = CommandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: callback.handleIncomingCommands,
  });

  const resolvedQueue = { id: queueUrl, name: queueUrl, arn: "" };
  return handleQueueEvent(resolvedQueue, commandTopicCallback.handleJsonCommands);
}
