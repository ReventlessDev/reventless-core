open PulumiAws;

let make: Reventless.EventCollector.Adapter.connectorMaker =
  (
    ~name,
    ~aggregateNames,
    ~extensionPointNames,
    ~policies,
    ~handleEvents,
    ~memorySize,
    ~timeout,
    ~opts,
  ) => {
    let eventHandlerLambda =
      policies // Pulumi.Output cannot be pushed into policies parameter !
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(policies =>
          Lambda.CallbackFunction.make(
            ~name,
            ~args=
              Lambda.CallbackFunction.Args.make(
                ~callback=
                  EventCollectorConnector_DynamoDbStream_Runtime.handleStreamEvent(
                    handleEvents,
                  ),
                ~policies,
                ~memorySize=memorySize->Pulumi.Input.wrap,
                ~timeout=timeout->Pulumi.Input.wrap,
                (),
              ),
            ~opts,
            (),
          )
        );

    let (dynamoDbStreamTopics, otherTopics) =
      Reventless.Util.Aggregate.Deploytime.eventTopics(aggregateNames)
      ->Belt.Array.concat(
          Reventless.Util.ExtensionPoint.Deploytime.eventTopics(
            extensionPointNames,
          ),
        )
      ->Belt.Array.partition(((service, _)) =>
          service == Util_DynamoDbStream.service
        );

    let _eventSourceMappings =
      dynamoDbStreamTopics->Belt.Array.map(
        Util_EventSourceMapping.subscribe(eventHandlerLambda, name, opts),
      );

    if (otherTopics->Belt.Array.length > 0) {
      let errors =
        otherTopics
        ->Belt.Array.map(((service, (sourceName, _))) =>
            {j|EventTopicPublisher_$service $sourceName|j}
          )
        ->Js.Array2.joinWith(",");
      Js.Exn.raiseError(
        {j|EventCollectorConnector_DynamoDbStream cannot connect to $errors|j},
      );
    } else {
      {resource: None};
    };
  };
