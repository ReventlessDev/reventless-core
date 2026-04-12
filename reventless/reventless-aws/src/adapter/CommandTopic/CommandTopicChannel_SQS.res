type callbackEvent = PulumiAws.SQS.Queue.event
type runtimeParts = Util.Lambda.runtimeParts
type channelParts = Util.SQS.channelParts

let connect = (
  ~name,
  ~channel: ReventlessCore.CommandTopic_Adapter.channel<
    callbackEvent,
    'context,
    Util.SQS.channelParts,
    runtimeParts,
  >,
  ~runtime: ReventlessCore.Runtime.environment<runtimeParts>,
  ~resources: array<ReventlessInfra.Adapter.resource>,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue = channel.parts.queue
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  open CommandTopicChannel_Helpers

  queue->createQueuePolicy(name, lambda, opts)
  lambdaRole->createLambdaPolicy(name, queue, resources, opts)
  let subscribeResource = lambda->subscribeLambda2SqsTopic(name, queue, opts)

  [subscribeResource]
}

let make: ReventlessCore.CommandTopic_Adapter.channelMaker<
  callbackEvent,
  'context,
  Util.SQS.channelParts,
  Util.Lambda.runtimeParts,
> = (~name, ~opts=?) => {
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let tags = AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType)
  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make, // TODO rethink timeout
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
        ->Stream.runForEach(jsons =>
          Effect.promise(() => publishJsons(jsons))
        )
    }),
    publishJsonsAndWait: None->Pulumi.Output.make,
    connect,
    handleChannelEvent: handleCommands =>
      resolvedQueueOutput->Pulumi.Output.apply(resolvedQueue =>
        resolvedQueue->CommandTopicChannel_SQS_Runtime.handleQueueEvent(handleCommands, ...)
      ),
  }
}
