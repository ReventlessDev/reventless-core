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
    ~args=SQS.Queue.Args.make(
      ~visibilityTimeoutSeconds=(6 * timeout)->Pulumi.Input.make,
      ~redrivePolicy=Util_DeadLetterQueue.queue["arn"]
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.Args.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      ~sqsManagedSseEnabled=false->Pulumi.Input.make,
      ~tags=[("Name", name), ("Type", "CommandTopic")]->Js.Dict.fromArray->Pulumi.Input.make,
      (),
    ),
    ~opts,
    (),
  )

  let _queuePolicy = {
    open Util_SqsQueuePolicy
    make(~name, ~queue, ~statements=[allowCloudWatchEvents], ~opts, ())
  }

  let handler = {
    open Lambda.CallbackFunction
    make(
      ~name,
      ~args=Args.make(
        ~callback=CommandTopicConnector_SQS_Runtime.handleQueueEvent(handleCommands, queue),
        ~policies=Lambda.Policy.defaultPolicies,
        ~memorySize=memorySize->Pulumi.Input.make,
        ~timeout=timeout->Pulumi.Input.make,
        ~tags=[("Name", name), ("Type", "CommandTopic")]->Js.Dict.fromArray->Pulumi.Input.make,
        (),
      ),
      ~opts,
      (),
    )
  }

  let _queueSubscription = queue->SQS.Queue.onEvent(~name, ~handler, ~opts, ())

  {
    resources: [queue->Util_SQS.toResource],
    publish: queue->CommandTopicConnector_SQS_Runtime.publish(Util_SQS_Runtime.service),
  }
}
