// SQS-backed CommandTopic channel with synchronous command execution.
// Uses a standard (non-FIFO) SQS queue for infrastructure.
// publishJsonsAndWait captures the command handler (set via handleChannelEvent) and
// runs it inline, returning typed CommandResult outcomes without a queue round-trip.
// Falls back to fire-and-forget + Pending when the handler is not yet registered
// (e.g. PerAggregate strategy where resolver and handler run in separate Lambdas).

type callbackEvent = PulumiAws.SQS.Queue.event
type runtimeParts = Util.Lambda.runtimeParts
type channelParts = Util.SQS.channelParts

let connect = CommandTopicChannel_SQS.connect

// See CommandTopicChannel_SQS_Async for the rationale behind these re-exports.
let setBatchSize = CommandTopicChannel_SQS.setBatchSize
let clearBatchSize = CommandTopicChannel_SQS.clearBatchSize

let make: ReventlessCore.CommandTopic_Adapter.channelMaker<
  callbackEvent,
  'context,
  Util.SQS.channelParts,
  Util.Lambda.runtimeParts,
> = (~name, ~opts=?) => {
  // Captured when handleChannelEvent is called; used by publishJsonsAndWait to
  // run the handler inline and collect typed outcomes without going through SQS.
  let handleCmdsRef: ref<option<ReventlessCore.CommandTopic.jsonCommandsHandler>> = ref(None)

  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let tags = AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType)
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags,
    },
    ~opts?,
  )

  let resolvedQueueOutput = queue->Util_SQS.toResolvedQueueOutput

  {
    ReventlessCore.CommandTopic_Adapter.parts: {queue: queue},
    resources: [queue->Util_SQS.toResource(~tags=tags->Pulumi.Output.fromInput)],
    publishJsons: resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue =>
      resolvedQueue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...)
    ),
    publishJsonsStream: resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue => {
      let publishJsons = resolvedQueue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...)
      stream =>
        stream
        ->Stream.grouped(10)
        ->Stream.runForEach(jsons => Effect.promise(() => publishJsons(jsons)))
    }),
    // publishJsonsAndWait runs the handler inline when available (Single runtime strategy).
    // Falls back to SQS fire-and-forget + Pending for PerAggregate strategy.
    publishJsonsAndWait: resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue => {
      let sendToSqs = resolvedQueue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...)
      let publishJsonsAndWait: ReventlessCore.CommandTopic.publishJsonsAndWait = async jsons => {
        switch handleCmdsRef.contents {
        | None =>
          // Handler not yet registered — fall back to fire-and-forget, return Pending
          let _ = await sendToSqs(jsons)
          jsons->Array.map(cmdJson =>
            ReventlessCore.CommandTopic.Pending({msgId: cmdJson.meta.msgId})
          )
        | Some(handleCmds) =>
          await ReventlessCore.CommandTopic.runInlineAndCollect(jsons, handleCmds)
        }
      }
      Some(publishJsonsAndWait)
    }),
    connect,
    handleChannelEvent: handleCommands => {
      handleCmdsRef.contents = Some(handleCommands)
      resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue =>
        resolvedQueue->CommandTopicChannel_SQS_Runtime.handleQueueEvent(handleCommands, ...)
      )
    },
  }
}
