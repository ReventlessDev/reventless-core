open PulumiAws
open Reventless.Util.Adapter

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
      ~visibilityTimeoutSeconds=timeout->Pulumi.Input.make,
      ~redrivePolicy=Util_DeadLetterQueue.queue["arn"]
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.Args.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      ~sqsManagedSseEnabled=false->Pulumi.Input.make,
      ~tags=AWS.tags(~name, Reventless.EventCollector.componentType),
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

  let eventHandlerLambda = Lambda.Policy.customPolicies(
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
        ~tags=AWS.tags(~name, Reventless.EventCollector.componentType),
        (),
      ),
      ~opts,
      (),
    )
  )

  let _queueSubscription = // Pulumi.Output cannot be pushed into handler parameter !
  eventHandlerLambda->Pulumi.Output.apply(eventHandlerLambda =>
    queue->SQS.Queue.onEvent(~name, ~handler=eventHandlerLambda, ~opts, ())
  )

  let _ =
    eventTopics
    ->partitionSupportedResources([Util.DynamoDbStream_Runtime.service, Util.SNS.service])
    ->Pulumi.Output.apply(((supportedResources, errorResources)) => {
      let (snsResources, otherResources) =
        supportedResources->partitionUnwrappedResourcesByService(Util.SNS.service)
      let _snsTopicSubscriptions = snsResources->Belt.Array.map(((sourceName, resources)) =>
        Util.SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName,
          ~topic=resources
          ->Util.SNS.findUnwrappedResource
          ->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      )

      let _eventSourceMappings = otherResources->Belt.Array.map(((sourceName, source)) =>
        Util.EventSourceMapping.subscribe(
          ~lambda=eventHandlerLambda,
          ~targetName=name,
          ~sourceName,
          ~source=source
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
    Reventless.EventCollector.Adapter.resources: [queue->Util_SQS.toResource],
    enqueueEvent: queue->EventCollectorConnector_SQS_Runtime.enqueueEvent,
  }
}
