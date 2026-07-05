// PgChangeFeedRelay Lambda entry point (scheduled poll — B2.3).
//
// Triggered on a schedule (EventBridge rate rule). Each invocation drains every
// Postgres DCB log listed in HANDLER_CONFIG from its checkpoint and relays the
// events, transformed into the {id, meta, event} shape, onto the plugin
// EventCollector SQS queue — which then fans out to projections, aggregate
// command topics, and the cross-plugin SNS EventTopic.
// See docs/plans/aws-postgres-change-feed-bridge.md.
//
// HANDLER_CONFIG shape:
//   { "logs": [ { "pgConnection": {host,port,database,username,secretArn},
//                 "logName": string,          // dcb_event.log_name
//                 "subscriber": string,        // dcb_subscription checkpoint key
//                 "targetQueueUrl": string,    // plugin EventCollector SQS URL
//                 "partitionTag"?: <derivedPartitionTag> } ] }

import { relay } from "@reventlessdev/reventless-aws/src/adapter/Postgres/PgChangeFeedRelay_Runtime.res.mjs";
import { sendMessage } from "@reventlessdev/reventless-aws/src/util/Util_SQS_Runtime.res.mjs";
import { makeQueueRef, log } from "./HandlerFactoryHelpers.mjs";

// Standard (non-FIFO) EventCollector queue — no message group id needed. The
// SQS handler parses each body straight back to JSON (Util_SQS_Runtime.parseSqsRecord).
function makeSendBatch(targetQueueUrl) {
  const queue = makeQueueRef(targetQueueUrl);
  return (jsons) =>
    Promise.all(jsons.map((json) => sendMessage(queue, undefined, JSON.stringify(json)))).then(
      () => {}
    );
}

export async function handler(_event, _context) {
  const configStr = process.env["HANDLER_CONFIG"] || '{"logs":[]}';
  const config = JSON.parse(configStr);
  const logs = config.logs || [];

  await Promise.all(
    logs.map(async (l) => {
      const sendBatch = makeSendBatch(l.targetQueueUrl);
      try {
        const count = await relay(l.pgConnection, l.logName, l.subscriber, l.partitionTag, sendBatch);
        log.debug("relayed " + count + " event(s) for " + l.logName, { comp: "PgChangeFeedRelay" });
      } catch (err) {
        // Log and continue — a failed log this tick is retried next tick from its
        // unchanged checkpoint (at-least-once; projections are idempotent).
        log.warn("relay failed for " + l.logName + ": " + (err?.message ?? String(err)), {
          comp: "PgChangeFeedRelay",
        });
      }
    })
  );
  return "";
}
