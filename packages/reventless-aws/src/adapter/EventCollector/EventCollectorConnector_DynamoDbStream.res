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
  let policies = Lambda.Policy.customPolicies(policy1, policy2) // TODO calculate real policies

  let _ = policies->Pulumi.Output.apply(policies => {
    let eventHandlerLambda = Lambda.CallbackFunction.make(
      ~name,
      ~args=Lambda.CallbackFunction.Args.make(
        ~callback=EventCollectorConnector_DynamoDbStream_Runtime.handleStreamEvent(
          handleEvents,
          ...
        ),
        ~policies,
        ~memorySize=memorySize->Pulumi.Input.make,
        ~timeout=timeout->Pulumi.Input.make,
        ~tags=AWS.tags(~name, Reventless.EventCollector.componentType),
      ),
      ~opts,
    )

    eventTopics
    ->Js.Dict.map((eventTopic: ReventlessSpec.EventTopic.outputs) => eventTopic.resources, _)
    ->Reventless.Util.Adapter.partitionSupportedResources([
      Util_DynamoDbStream_Runtime.service,
      Util_SNS_FIFO.service,
    ])
    ->Pulumi.Output.apply(((dynamoDbStreamResources, errorResources)) => {
      let _eventSourceMappings: array<EventSourceMapping.t> =
        dynamoDbStreamResources->Belt.Array.map(
          ((sourceName, sources)) =>
            Util_EventSourceMapping.subscribe(
              ~batchSize=25,
              ~lambda=eventHandlerLambda->Pulumi.Output.make,
              ~targetName=name,
              ~sourceName,
              ~source=sources->Array.getUnsafe(0)->Reventless.AdapterDeploytime.unwrappedToResource,
              ~opts,
            ),
        )

      if errorResources->Belt.Array.length > 0 {
        let eventTopicNames = errorResources->Js.Array2.joinWith(",")
        Js.Exn.raiseError(__MODULE__ ++ ` cannot connect to EventTopic(s) ${eventTopicNames}`)
      }
    })
  })

  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Js.log4(__MODULE__ ++ " supports no enqueueEvent:", delay, id, messageBody)->Js.Promise.resolve
  {
    Reventless.EventCollector.Adapter.resources: [],
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
  }
}
