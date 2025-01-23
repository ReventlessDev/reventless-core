open PulumiAws

let make: Reventless.CommandTopic.Adapter.connectorMaker = (
  ~name,
  ~handleCommands,
  ~memorySize,
  ~timeout,
  ~opts,
) => {
  let queue = SQS.Queue.make(
    ~name,
    ~args={
      SQS.Queue.fifoQueue: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: (6 * timeout)->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
      ->Pulumi.Output.apply(dlqArn => {
        SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      })
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
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
    resources: [queue->Util_SQS_FIFO.toResource],
    publish: queue
    ->Util_SQS_Runtime.toRuntimeQueue
    ->(CommandTopicConnector_SQS_Runtime.publish(Util_SQS_FIFO.service, ...)),
  }
}
