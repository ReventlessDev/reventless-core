open PulumiAws

let make: Reventless.EventCollector.Adapter.connectorMaker = (
  ~name,
  ~eventTopics,
  ~handleEvents,
  ~memorySize,
  ~timeout,
  ~policy1,
  ~policy2,
  ~opts,
) => {
  let queue = SQS.Queue.make(
    ~name,
    ~args=SQS.Queue.Args.make(
      ~fifoQueue=true->Pulumi.Input.make,
      ~deduplicationScope=#messageGroup,
      ~fifoThroughputLimit=#perMessageGroupId,
      ~contentBasedDeduplication=true->Pulumi.Input.make,
      ~visibilityTimeoutSeconds=timeout->Pulumi.Input.make,
      ~redrivePolicy=Util_DeadLetterQueue.fifoQueue["arn"]
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.Args.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      ~sqsManagedSseEnabled=false->Pulumi.Input.make,
      ~tags=[("Name", name), ("Type", "EventCollector")]->Js.Dict.fromArray->Pulumi.Input.make,
      (),
    ),
    ~opts,
    (),
  )

  let _queuePolicy = {
    open Util_SqsQueuePolicy
    make(
      ~name,
      ~queue,
      ~statements=[allowAllSnsTopicsSendMessage(queue), allowCloudWatchEvents],
      ~opts,
      (),
    )
  }

  let eventHandlerLambda = PulumiAws.Lambda.Policy.customPolicies(
    policy1,
    policy2,
  )->Pulumi.Output.apply(policies =>
    // TODO calculate real policies
    Lambda.CallbackFunction.make(
      ~name,
      ~args=Lambda.CallbackFunction.Args.make(
        ~callback=EventCollectorConnector_SQS_Runtime.handleCallbackEvent(handleEvents, queue),
        ~policies,
        ~memorySize=memorySize->Pulumi.Input.make,
        ~timeout=timeout->Pulumi.Input.make,
        ~tags=[("Name", name), ("Type", "EventCollector")]->Js.Dict.fromArray->Pulumi.Input.make,
        (),
      ),
      ~opts,
      (),
    )
  )

  let _queueSubscription =
    eventHandlerLambda->Pulumi.Output.apply(eventHandlerLambda =>
      queue->SQS.Queue.onEvent(~name, ~handler=eventHandlerLambda, ~opts, ())
    )

  let _ =
    eventTopics
    ->Reventless.Util.Adapter.partitionSupportedResources([
      Util_DynamoDbStream_Runtime.service,
      Util_SNS_FIFO.service,
    ])
    ->Pulumi.Output.apply(((supportedResources, errorResources)) => {
      let (snsFifoResources, otherResources) =
        supportedResources->Reventless.Util.Adapter.partitionUnwrappedResourcesByService(
          Util_SNS_FIFO.service,
        )

      let _snsFifoTopicSubscriptions = snsFifoResources->Belt.Array.map(((sourceName, topic)) =>
        Util_SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName,
          ~topic=topic
          ->Util.SNS_FIFO.findTopicInUnwrappedResources
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      )

      let _eventSourceMappings = otherResources->Belt.Array.map(((sourceName, resources)) =>
        Util_EventSourceMapping.subscribe(
          ~lambda=eventHandlerLambda,
          ~targetName=name,
          ~sourceName,
          ~source=resources
          ->Util.DynamoDbStream.findUnwrappedResource
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
          (),
        )
      )

      if errorResources->Belt.Array.length > 0 {
        let eventTopicNames = errorResources->Js.Array2.joinWith(",")
        Js.Exn.raiseError(__MODULE__ ++ ` cannot connect to EventTopic(s) ${eventTopicNames}`)
      }
    })

  {
    Reventless.EventCollector.Adapter.resources: [queue->Util_SQS_FIFO.toResource],
    enqueueEvent: queue->EventCollectorConnector_SQS_Runtime.enqueueFifoEvent,
  }
}
