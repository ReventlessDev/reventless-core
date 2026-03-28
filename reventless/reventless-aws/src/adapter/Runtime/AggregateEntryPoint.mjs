// Aggregate Lambda entry point.
// At cold start: reads HANDLER_CONFIG, dynamically imports Spec+Behavior modules,
// wires EventLog_Operations, Aggregate_Callback, CommandTopic_Callback.
// Handles both SQS CommandTopic events (Route 2) and AppSync direct invocation (Route 1).

import * as Effect from "effect/Effect";
import { patchSpecId, makeQueueRef } from "./HandlerFactoryHelpers.mjs";
import { tag as requestContextTag } from "@reventlessdev/reventless-core/src/RequestContext.res.mjs";
import { Make as eventLogOperationsMake } from "@reventlessdev/reventless-core/src/components/EventLog/EventLog_Operations.res.mjs";
import { Make as aggregateCallbackMake } from "@reventlessdev/reventless-core/src/components/Aggregate/Aggregate_Callback.res.mjs";
import { Make as commandTopicCallbackMake } from "@reventlessdev/reventless-core/src/components/CommandTopic/CommandTopic_Callback.res.mjs";
import { makeGenerateCommand } from "@reventlessdev/reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res.mjs";
import { append, replay, replayStream, appendStream } from "@reventlessdev/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res.mjs";
import { handleQueueEvent, publishJsons as sqsPublishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

const dynamicImport = (specifier) => import('/var/task/node_modules/' + specifier);

function buildCommandTopicHandler(specModule, behaviorModule, eventLogTableName, queueUrl) {
  const patchedSpec = patchSpecId(specModule);
  const resolvedTable = { name: eventLogTableName };
  const rawStorageOps = {
    append: append(resolvedTable),
    replay: replay(resolvedTable),
    replayStream: replayStream(resolvedTable),
    appendStream: appendStream(resolvedTable),
  };
  const eventLogOps = eventLogOperationsMake(patchedSpec)({
    Spec: patchedSpec,
    EventTopic: { Spec: patchedSpec },
    eventTopic: { publish: async () => {} },
    storage: rawStorageOps,
  });
  const aggregateCallback = aggregateCallbackMake(patchedSpec)(behaviorModule)({
    Spec: patchedSpec,
    EventLog: { Spec: patchedSpec },
    eventLog: eventLogOps,
  });
  const commandTopicCallback = commandTopicCallbackMake(patchedSpec)({
    Spec: patchedSpec,
    commandsHandler: aggregateCallback.handleCommands,
  });
  return handleQueueEvent(makeQueueRef(queueUrl), commandTopicCallback.handleJsonCommands);
}

function buildCommandGeneratorHandler(specModule, _behaviorModule, queueUrl) {
  const resolvedQueue = makeQueueRef(queueUrl);
  const publishJsons = sqsPublishJsons(resolvedQueue, "SQS_FIFO");
  const generateCommand = makeGenerateCommand(publishJsons, specModule.name, specModule.commandSchema, "Aggregate", undefined);
  return (event, _context) => {
    // Add identity fallback: use payload.identity if present, otherwise construct from meta.user.
    const identity = (event.identity != null && typeof event.identity === 'object')
      ? event.identity
      : {
          userId: event.meta?.user ?? "anonymous",
          username: event.meta?.user ?? "anonymous",
          groups: [],
          provider: { TAG: "Custom", _0: "aws" },
        };
    return generateCommand({ ...event, identity });
  };
}

function runEffect(correlationId, effect) {
  return effect
    .pipe(Effect.provideService(requestContextTag, { correlationId: correlationId || "unknown" }))
    .pipe(Effect.runPromise);
}

function groupBySource(records) {
  const dict = {};
  records.forEach(record => {
    const arn = record.eventSourceARN;
    const existing = dict[arn] || [];
    dict[arn] = existing.concat([record]);
  });
  return dict;
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

async function buildAllHandlers() {
  const configStr = process.env["HANDLER_CONFIG"] || '{"handlers":[]}';
  const config = JSON.parse(configStr);
  const cmdTopicHandlers = {};
  const cmdGenHandlers = {};
  await Promise.all(config.handlers.map(async h => {
    const specModule = await dynamicImport(h.specModule);
    const behaviorModule = await dynamicImport(h.behaviorModule);
    cmdTopicHandlers[h.queueArn] = buildCommandTopicHandler(specModule, behaviorModule, h.eventLogTable, h.queueUrl);
    cmdGenHandlers[specModule.name] = buildCommandGeneratorHandler(specModule, behaviorModule, h.queueUrl);
  }));
  return [cmdTopicHandlers, cmdGenHandlers];
}

const initPromise = buildAllHandlers();

export async function handler(event, context) {
  const [cmdTopicHandlers, cmdGenHandlers] = await initPromise;

  // Route 1: AppSync direct invocation
  if (event.command != null && event.arguments != null) {
    const entries = Object.entries(cmdGenHandlers);
    const len = entries.length;
    let i = 0;
    let result = "";
    let found = false;
    while (i < len && !found) {
      const [name, cmdGenHandler] = entries[i];
      try {
        const r = await runEffect(undefined, cmdGenHandler(event, context));
        console.log("----- commandGeneratorHandler: processed command via " + name);
        result = r;
        found = true;
      } catch (_) {
        i = i + 1;
      }
    }
    if (!found) {
      console.warn("commandGeneratorHandler: no handler matched command");
    }
    return result;
  }

  // Route 2: SQS CommandTopic events
  const records = event.Records || [];
  const correlationId = extractCorrelationId(records);
  const grouped = groupBySource(records);
  await Promise.all(Object.entries(grouped).map(async ([arn, subRecords]) => {
    const cmdHandler = cmdTopicHandlers[arn];
    if (cmdHandler !== undefined) {
      console.log("----- aggregateHandler: found handler for CommandTopic " + arn);
      await runEffect(correlationId, cmdHandler({ Records: subRecords }, context));
    } else {
      console.warn("aggregateHandler: no handler found: " + arn);
    }
  }));
  return "";
}
