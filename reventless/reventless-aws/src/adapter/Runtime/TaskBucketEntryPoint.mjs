// TaskBucket Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports callback module,
// wires TaskBucket_S3_Runtime.handleBucketEvent, dispatches task actions to SQS.

import { makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { handleBucketEvent } from "@reventlessdev/reventless-aws/src/adapter/Task/TaskBucket_S3_Runtime.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

async function buildHandler() {
  const configStr = process.env["HANDLER_CONFIG"] || "{}";
  const config = JSON.parse(configStr);

  const callbackModule = await dynamicImport(config.callbackModule);
  const bucketCallback = callbackModule.callback;
  const handleEvents = handleBucketEvent(bucketCallback);

  // Build publishCommands dict from env var queue URLs
  const publishCommandsFns = {};
  for (const [envVarName, aggName] of Object.entries(config.publishToAggregates || {})) {
    const queueUrl = process.env[envVarName] || "";
    if (queueUrl !== "") {
      publishCommandsFns[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
    }
  }

  return async (event, _context) => {
    const taskActions = await handleEvents(event, _context);

    await Promise.all(taskActions.map(async action => {
      switch (action.TAG) {
        case 0: {
          // PublishCommands(aggregateName, cmdJsons)
          const aggregateName = action._0;
          const cmdJsons = action._1;
          const pub = publishCommandsFns[aggregateName];
          if (pub !== undefined) {
            await pub(cmdJsons);
          } else {
            console.warn(`TaskBucketEntryPoint: No publish function for aggregate "${aggregateName}"`);
          }
          break;
        }
        case 1:
          console.warn("TaskBucketEntryPoint: CreateSchedule not supported in bundled mode");
          break;
        case 2:
          console.warn("TaskBucketEntryPoint: DeleteSchedule not supported in bundled mode");
          break;
      }
    }));

    return "";
  };
}

const initPromise = buildHandler();

export async function handler(event, context) {
  const s3Handler = await initPromise;
  return await s3Handler(event, context);
}
