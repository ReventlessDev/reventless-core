type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let connect = EventCollectorChannel_SQS.connect

let make: Reventless.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
  ~name,
  ~eventTopics,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

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
      tags: AWS.Tags.make(~name, Reventless.EventCollector.componentType),
    },
    ~opts,
  )

  let enqueueEvent =
    queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
    )

  let handleChannelEvent = handleEvents =>
    queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(handleEvents, ...))
    )

  let eventTopicResources =
    eventTopics
    ->Js.Dict.values
    ->Array.map(outputs => outputs.resources->Array.getUnsafe(0)) // FIXME

  {
    Reventless.EventCollector_Adapter.parts: {queue: queue},
    resources: eventTopicResources->Array.concat([queue->Util_SQS.toResource]),
    enqueueEvent,
    handleChannelEvent,
  }
}
