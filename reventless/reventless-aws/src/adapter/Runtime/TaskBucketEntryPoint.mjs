// TaskBucket Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports callback module,
// wires TaskBucket_S3_Runtime.handleBucketEvent, dispatches task actions to SQS.

import { makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { handleBucketEvent } from "@reventlessdev/reventless-aws/src/adapter/Task/TaskBucket_S3_Runtime.res.mjs";
import { publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";
import {
  CloudWatchEventsClient,
  PutRuleCommand,
  PutTargetsCommand,
  RemoveTargetsCommand,
  DeleteRuleCommand,
} from "@aws-sdk/client-cloudwatch-events";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

// Mirrors ScheduledPublisher_CloudWatchEvents_Runtime.toScheduleExpression — kept
// in sync manually because that runtime helper isn't bundled in this Lambda.
function toScheduleExpression(rate) {
  // rate is a serialized variant from Reventless.Schedule.rate
  switch (rate.TAG) {
    case "Single": {
      const [year, month, day, hour, minute] = [rate._0, rate._1, rate._2, rate._3, rate._4];
      return `cron(${minute} ${hour} ${day} ${month} ? ${year})`;
    }
    case "Minutes": {
      const n = rate._0;
      return `rate(${n} minute${n === 1 ? "" : "s"})`;
    }
    case "Hours": {
      const n = rate._0;
      return `rate(${n} hour${n === 1 ? "" : "s"})`;
    }
    case "Days": {
      const n = rate._0;
      return `rate(${n} day${n === 1 ? "" : "s"})`;
    }
    case "Daily":
      return `cron(${rate._1} ${rate._0} * * * *)`;
    case "Weekdays":
      return `cron(${rate._1} ${rate._0} ? * MON-FRI *)`;
    case "WeekdaysAndSaturday":
      return `cron(${rate._1} ${rate._0} ? * MON-SAT *)`;
    default:
      throw new Error(`TaskBucketEntryPoint: unknown schedule rate ${JSON.stringify(rate)}`);
  }
}

let cachedScheduler = null;
function makeSchedulerOps(schedulerCfg) {
  if (!schedulerCfg) return null;
  if (cachedScheduler) return cachedScheduler;
  const roleArn = process.env[schedulerCfg.roleArnEnv];
  const targetArn = process.env[schedulerCfg.targetArnEnv];
  const targetName = process.env[schedulerCfg.targetNameEnv];
  if (!roleArn || !targetArn || !targetName) {
    console.warn("TaskBucketEntryPoint: scheduler env vars missing — schedules will no-op");
    return null;
  }
  const client = new CloudWatchEventsClient({});
  cachedScheduler = {
    createSchedule: async (schedule) => {
      await client.send(new PutRuleCommand({
        Name: schedule.name,
        ScheduleExpression: toScheduleExpression(schedule.rate),
        RoleArn: roleArn,
        State: "ENABLED",
      }));
      await client.send(new PutTargetsCommand({
        Rule: schedule.name,
        Targets: [{ Arn: targetArn, Id: targetName, Input: schedule.payload }],
      }));
    },
    deleteSchedule: async (name) => {
      await client.send(new RemoveTargetsCommand({ Rule: name, Ids: [targetName] }));
      await client.send(new DeleteRuleCommand({ Name: name }));
    },
  };
  return cachedScheduler;
}

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
        case "PublishCommands": {
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
        case "CreateSchedule": {
          const ops = makeSchedulerOps(config.scheduler);
          if (ops) {
            await ops.createSchedule(action._0);
          } else {
            console.warn("TaskBucketEntryPoint: CreateSchedule skipped — no scheduler configured for this Task (add sideEffects to setup)");
          }
          break;
        }
        case "DeleteSchedule": {
          const ops = makeSchedulerOps(config.scheduler);
          if (ops) {
            await ops.deleteSchedule(action._0);
          } else {
            console.warn("TaskBucketEntryPoint: DeleteSchedule skipped — no scheduler configured for this Task (add sideEffects to setup)");
          }
          break;
        }
        default:
          console.warn(`TaskBucketEntryPoint: unknown task action TAG ${action.TAG}`);
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
