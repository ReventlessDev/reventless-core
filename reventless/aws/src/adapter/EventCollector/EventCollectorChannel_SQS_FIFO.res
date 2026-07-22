type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let connect = EventCollectorChannel_SQS.connect

let make: ReventlessCore.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
  ~name,
  ~eventTopics,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.EventCollector.componentType, ~role=EventCollector)
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.fifoQueue: true->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: 30->Pulumi.Input.make, // TODO fix timeout
      redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags,
    },
    ~opts,
  )

  let enqueueEvent =
    queue
    ->Util_SQS.toResolvedQueueOutput
    ->Pulumi.Output.apply(resolvedQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(resolvedQueue, ...)
    )

  let handleChannelEvent = handleEvents =>
    queue
    ->Util_SQS.toResolvedQueueOutput
    ->Pulumi.Output.apply(resolvedQueue =>
      resolvedQueue->EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(handleEvents, ...)
    )

  let eventTopicResources =
    eventTopics
    ->Dict.valuesToArray
    ->Array.map(outputs => outputs.resources->Array.getUnsafe(0)) // FIXME

  {
    ReventlessCore.EventCollector_Adapter.parts: {queue: queue},
    resources: eventTopicResources->Array.concat([queue->Util_SQS.toResource(~tags=tags->Pulumi.Output.fromInput)]),
    enqueueEvent,
    handleChannelEvent,
  }
}
