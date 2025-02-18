open PulumiAws

let make: Reventless.CommandTopic_Adapter.channelMaker = (~name, ~opts=?) => {
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)
  let queue = SQS.Queue.make(
    ~name,
    ~args={
      SQS.Queue.visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make, // TODO rethink timeout
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.tags(~name, Reventless.CommandTopic.componentType),
    },
    ~opts?,
  )

  let _queuePolicy = {
    open Util_SqsQueuePolicy
    make(~name, ~queue, ~statements=[allowCloudWatchEvents], ~opts?)
  }

  {
    resources: [queue->Util_SQS.toResource],
    publishJsons: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(CommandTopicChannel_SQS_Runtime.publishJsons(Util_SQS.service, ...))
    ),
  }
}
