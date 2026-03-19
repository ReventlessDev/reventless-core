/**
 * Factory for reconstructing Task bucket handler chains in bundled Lambda handlers.
 *
 * At deploy time, Task bucket handlers capture publishCommands (SQS send closures)
 * and optionally SideEffectHandler operations via Pulumi Output chains. In bundled
 * Lambdas, the user's bucket callback is imported statically and publishCommands
 * are reconstructed from SQS queue URLs in environment variables.
 *
 * Handler chain (same as deploy-time):
 *   S3 event
 *   → TaskBucket_S3_Runtime.handleBucketEvent(callback)
 *   → callback(~eventName, ~key) → array<taskAction>
 *   → taskActionsHandler dispatches: PublishCommands → SQS send
 */

import { handleBucketEvent } from "@reventlessdev/reventless-aws/src/adapter/Task/TaskBucket_S3_Runtime.res.mjs";
import { publishJsons } from "@reventlessdev/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res.mjs";

/**
 * Create a Task bucket handler for a single bucket.
 *
 * @param {Object} params
 * @param {Object} params.callbackModule - Compiled module exporting `callback: (~eventName, ~key) => promise<array<taskAction>>`
 * @param {Object} params.publishToAggregatesEnv - Dict of aggregate name → SQS queue URL from env vars
 * @returns {Function} Handler: (S3Event, context) => promise<string>
 */
export function createTaskBucketHandler({ callbackModule, publishToAggregatesEnv }) {
  // Reconstruct publishCommands from SQS queue URLs.
  // Each aggregate name maps to a publishJsons function that sends to its command topic queue.
  const publishCommandsFns = {};
  for (const [aggName, queueUrl] of Object.entries(publishToAggregatesEnv)) {
    if (queueUrl) {
      publishCommandsFns[aggName] = publishJsons(queueUrl, "SQS_FIFO");
    }
  }

  // The user's bucket callback — must export `callback` matching Task.bucketCallback type
  const bucketCallback = callbackModule.callback;

  // Wrap the callback in S3 event parsing
  const handleEvents = handleBucketEvent(bucketCallback);

  return async (event, context) => {
    const taskActions = await handleEvents(event, context);

    // Dispatch task actions
    for (const action of taskActions) {
      // ReScript variant encoding: tagged union with TAG property
      // PublishCommands(name, cmds) → { TAG: 0, _0: name, _1: cmds }
      // CreateSchedule(schedule) → { TAG: 1, _0: schedule }
      // DeleteSchedule(id) → { TAG: 2, _0: id }
      if (typeof action === "object" && action !== null) {
        switch (action.TAG) {
          case 0: {
            // PublishCommands
            const aggregateName = action._0;
            const cmdJsons = action._1;
            const pub = publishCommandsFns[aggregateName];
            if (pub) {
              await pub(cmdJsons);
            } else {
              console.warn(
                `BundledTaskHandlerFactory: No publish function for aggregate "${aggregateName}"`
              );
            }
            break;
          }
          case 1: {
            // CreateSchedule — not supported in bundled mode
            console.warn(
              "BundledTaskHandlerFactory: CreateSchedule not supported in bundled mode (no-op)"
            );
            break;
          }
          case 2: {
            // DeleteSchedule — not supported in bundled mode
            console.warn(
              "BundledTaskHandlerFactory: DeleteSchedule not supported in bundled mode (no-op)"
            );
            break;
          }
        }
      }
    }

    return "";
  };
}
