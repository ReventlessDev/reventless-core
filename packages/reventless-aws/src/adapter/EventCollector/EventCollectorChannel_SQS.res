open PulumiAws
open Reventless.Util.Adapter

let make: Reventless.EventCollector_Adapter.channelMaker = (
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
    ~args={
      SQS.Queue.visibilityTimeoutSeconds: 120->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.tags(~name, Reventless.EventCollector.componentType),
    },
    ~opts,
  )

  let _queuePolicy = {
    open Util_SqsQueuePolicy
    make(
      ~name,
      ~queue,
      ~statements=[allowAllSnsTopicsSendMessage(queue), allowCloudWatchEvents],
      ~opts,
    )
  }

  let _ =
    (
      eventTopics
      ->Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _)
      ->Reventless.Util.Adapter.partitionSupportedResources([
        Util_DynamoDbStream_Runtime.service,
        Util_SNS.service,
      ]),
      queue->Util_SQS.toRuntimeQueueOutput,
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply((((supportedResources, errorResources), runtimeQueue)) => {
      let eventHandlerLambda = Lambda.Policy.customPolicies(
        policy1,
        policy2,
      )->Pulumi.Output.apply(policies =>
        // TODO calculate real policies
        Lambda.CallbackFunction.make(
          ~name,
          ~args=Lambda.CallbackFunction.Args.make(
            ~callback=EventCollectorChannel_SQS_Runtime.handleCallbackEvent(
              handleEvents,
              runtimeQueue,
              ...
            ),
            ~policies,
            ~memorySize=memorySize->Pulumi.Input.make,
            ~timeout=timeout->Pulumi.Input.make,
            ~tags=AWS.tags(~name, Reventless.EventCollector.componentType),
          ),
          ~opts,
        )
      )

      let _queueSubscription = // Pulumi.Output cannot be pushed into handler parameter !
      eventHandlerLambda->Pulumi.Output.apply(eventHandlerLambda =>
        queue->SQS.Queue.onEvent(~name, ~handler=eventHandlerLambda, ~opts)
      )

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
        )
      )

      if errorResources->Belt.Array.length > 0 {
        let eventTopicNames = errorResources->Js.Array2.joinWith(",")
        Js.Exn.raiseError(__MODULE__ ++ ` cannot connect to EventTopic(s) ${eventTopicNames}`)
      }
    })

  {
    Reventless.EventCollector_Adapter.resources: [queue->Util_SQS.toResource],
    enqueueEvent: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
    ),
  }
}
