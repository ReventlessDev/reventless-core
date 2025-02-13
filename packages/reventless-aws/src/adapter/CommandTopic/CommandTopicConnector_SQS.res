open PulumiAws

let make: Reventless.CommandTopic_Adapter.connectorMaker = (
  ~name,
  ~handleCommands,
  ~memorySize,
  ~timeout,
  ~opts,
) => {
  let queue = SQS.Queue.make(
    ~name,
    ~args={
      SQS.Queue.visibilityTimeoutSeconds: (6 * timeout)->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.tags(~name, Reventless.CommandTopic.componentType),
    },
    ~opts,
  )

  let _queuePolicy = {
    open Util_SqsQueuePolicy
    make(~name, ~queue, ~statements=[allowCloudWatchEvents], ~opts)
  }

  let _ =
    queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue => {
      let handler = {
        open Lambda.CallbackFunction
        make(
          ~name,
          ~args=Args.make(
            ~callback=CommandTopicConnector_SQS_Runtime.handleQueueEvent(
              handleCommands,
              runtimeQueue,
              ...
            ),
            ~policies=Lambda.Policy.defaultPolicies,
            ~memorySize=memorySize->Pulumi.Input.make,
            ~timeout=timeout->Pulumi.Input.make,
            ~tags=AWS.tags(~name, Reventless.CommandTopic.componentType),
          ),
          ~opts,
        )
      }

      let _queueSubscription = queue->SQS.Queue.onEvent(~name, ~handler, ~opts)
    })

  {
    resources: [queue->Util_SQS.toResource],
    publishJsons: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(CommandTopicConnector_SQS_Runtime.publishJsons(Util_SQS_Runtime.service, ...))
    ),
  }
}
