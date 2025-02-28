type callbackEvent = PulumiAws.Lambda.CallbackFunction.event

let subscribe = (
  ~name,
  ~eventTopics,
  ~channel as _,
  ~runtime: Reventless.Runtime.environment,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let handler =
    runtime.resources
    ->Util.Lambda.findResource
    ->Util.Lambda.fromResource
  let eventTopicResources =
    eventTopics
    ->(Js.Dict.map((eventTopic: Reventless.EventTopic.outputs) => eventTopic.resources, _))
    ->Reventless.Util.Adapter.partitionSupportedResources([
      Util_DynamoDbStream_Runtime.service,
      Util_SNS_FIFO.service,
    ])

  let _ =
    (eventTopicResources, handler)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply((((dynamoDbStreamResources, errorResources), handler)) => {
      let _eventSourceMappings: array<PulumiAws.EventSourceMapping.t> =
        dynamoDbStreamResources->Belt.Array.map(((sourceName, sources)) =>
          Util_EventSourceMapping.subscribe(
            ~batchSize=25,
            ~lambda=handler->Pulumi.Output.make,
            ~targetName=name,
            ~sourceName,
            ~source=sources->Array.getUnsafe(0)->Reventless.AdapterDeploytime.unwrappedToResource,
            ~opts,
          )
        )

      if errorResources->Belt.Array.length > 0 {
        let eventTopicNames = errorResources->Js.Array2.joinWith(",")
        Js.Exn.raiseError(__MODULE__ ++ ` cannot connect to EventTopic(s) ${eventTopicNames}`)
      }
    })

  []
}

let make: Reventless.EventCollector_Adapter.channelMaker<callbackEvent, 'context> = (
  ~name as _,
  ~opts as _,
) => {
  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Js.log4(__MODULE__ ++ " supports no enqueueEvent:", delay, id, messageBody)->Js.Promise.resolve

  {
    Reventless.EventCollector.resources: [],
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    subscribe,
    handleChannelEvent: handleEvents =>
      Pulumi.Output.make(EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...)),
  }
}
