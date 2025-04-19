type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let connect = (
  ~name,
  ~channelSpecs: array<
    Reventless.EventCollector_Adapter.channelSpec<callbackEvent, 'context, channelParts>,
  >,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queues = channelSpecs->Array.map(channelSpec => channelSpec.channel.parts.queue)
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  open EventCollectorChannel_Common

  let _ = channelSpecs->Array.map(({channel, resources}) => {
    let queue = channel.parts.queue
    queue->connectSqsQueue2SnsTopics(name, resources, opts)
  })

  let queues = channelSpecs->Array.map(({channel}) => channel.parts.queue)
  let eventTopics =
    channelSpecs->Array.reduce(Js.Dict.empty(), (acc, {eventTopics}) =>
      acc->Dict.assign(eventTopics)
    )
  let resources = channelSpecs->Array.map(({resources}) => resources)->Array.flat

  lambda->connectLambda(name, lambdaRole, queues, eventTopics, resources, opts)
}

let make: Reventless.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
  ~name,
  ~eventTopics,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

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
