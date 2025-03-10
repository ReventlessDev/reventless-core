type callbackEvent = PulumiAws.SQS.Queue.event

let subscribe = (
  ~name,
  ~channel: Reventless.CommandTopic_Adapter.channel<callbackEvent, 'context>,
  ~runtime: Reventless.Runtime.environment,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue =
    channel.resources
    ->Util.SQS.findResource
    ->Util.SQS.fromResource

  let handler =
    runtime.resources
    ->Util.Lambda.findResource
    ->Util.Lambda.fromResource

  let resource =
    (queue, handler)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queue, handler)) =>
      queue->PulumiAws.SQS.Queue.onEvent(~name, ~handler, ~opts)->Util.SQS.Subscription.toResource
    )
    ->Reventless.Adapter.outputToResource
  [resource]
}

let make: Reventless.CommandTopic_Adapter.channelMaker<callbackEvent, 'context> = (
  ~name,
  ~opts=?,
) => {
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

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
      tags: AWS.Tags.make(~name, Reventless.CommandTopic.componentType),
    },
    ~opts?,
  )

  let _queuePolicy = {
    Util.SqsQueuePolicy.make(
      ~name,
      ~queue,
      ~statements=[Util.SqsQueuePolicy.allowCloudWatchEvents],
      ~opts?,
    )
  }

  {
    Reventless.CommandTopic_Adapter.resources: [queue->Util_SQS.toResource],
    publishJsons: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...))
    ),
    subscribe,
    handleChannelEvent: handleCommands =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue =>
        runtimeQueue->(CommandTopicChannel_SQS_Runtime.handleQueueEvent(handleCommands, ...))
      ),
  }
}
