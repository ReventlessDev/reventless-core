// FIFO SQS-backed CommandTopic channel with fire-and-forget semantics.
// Opt-in for high-contention aggregates and internal automation where
// ordering guarantees matter more than synchronous command results.
// Mutations return CommandPending — the client subscribes for the eventual result.

type callbackEvent = PulumiAws.SQS.Queue.event
type runtimeParts = Util.Lambda.runtimeParts
type channelParts = Util.SQS.channelParts

let connect = CommandTopicChannel_SQS.connect

// Re-export per-flavor SQS event-source `batchSize` setters from the shared
// SQS connect impl, so runtime builders can configure them via the aliased
// module (`CommandTopicChannel.SQS_Async.setBatchSize`).
let setBatchSize = CommandTopicChannel_SQS.setBatchSize
let clearBatchSize = CommandTopicChannel_SQS.clearBatchSize

let make: ReventlessCore.CommandTopic_Adapter.channelMaker<
  callbackEvent,
  'context,
  Util.SQS.channelParts,
  Util.Lambda.runtimeParts,
> = (~name, ~owner, ~opts=?) => {
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)
  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.CommandTopic.componentType, ~role=CommandTopic, ~owner?)
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.fifoQueue: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
      ->Pulumi.Output.apply(dlqArn => {
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      })
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
      tags,
    },
    ~opts?,
  )

  let resolvedQueueOutput = queue->Util_SQS.toResolvedQueueOutput
  let queueResource = queue->Util_SQS.toResource(~tags=tags->Pulumi.Output.fromInput)

  // Async aggregates and StateChangeSlices land here; same capture so a slice
  // targeting one is routed to it rather than to the plugin's DCB topic.
  CommandTopicRegistry.register(~owner, ~queueUrl=queue.id, ~resource=queueResource, ~isFifo=false)

  {
    parts: {queue: queue},
    resources: [queue->Util_SQS_FIFO.toResource(~tags=tags->Pulumi.Output.fromInput)],
    publishJsons: resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue =>
      resolvedQueue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO, ...)
    ),
    publishJsonsStream: resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue => {
      let publishJsons =
        resolvedQueue->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO, ...)
      stream =>
        stream
        ->Stream.grouped(10)
        ->Stream.runForEach(jsons => Effect.promise(() => publishJsons(jsons)))
    }),
    publishJsonsAndWait: None->Pulumi.Output.make,
    connect,
    handleChannelEvent: handleCommands =>
      resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue =>
        resolvedQueue->CommandTopicChannel_SQS_Runtime.handleQueueEvent(handleCommands, ...)
      ),
  }
}
