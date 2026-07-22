type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let connect = (
  ~name,
  ~channelSpecs: array<
    ReventlessCore.EventCollector_Adapter.channelSpec<callbackEvent, 'context, channelParts>,
  >,
  ~runtime: ReventlessCore.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  open EventCollectorChannel_Helpers

  let _ = channelSpecs->Array.map(({channel, eventTopics}) => {
    let queue = channel.parts.queue
    queue->connectSqsQueue2SnsTopics(name, eventTopics, opts)
  })

  let queues = channelSpecs->Array.map(({channel}) => channel.parts.queue)
  let eventTopics =
    channelSpecs->Array.reduce(Dict.make(), (acc, {eventTopics}) => acc->Dict.assign(eventTopics))
  let resources = channelSpecs->Array.map(({resources}) => resources)->Array.flat

  lambda->connectLambda(name, lambdaRole, queues, eventTopics, resources, opts)
}

let make: ReventlessCore.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
  ~name,
  ~eventTopics,
  ~owner, ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.EventCollector.componentType, ~role=EventCollector, ~owner?)
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: 120->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
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
