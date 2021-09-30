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
    ~resources,
  ) => {
    Js.log(
      __MODULE__
      ++ {j|.make: name=$name, aggregateNames=$aggregateNames, extensionPointNames=$extensionPointNames|j},
    );
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
      resources
      ->Reventless.Util.Aggregate.eventTopics(aggregateNames)
      ->Belt.Array.concat(
          resources->Reventless.Util.ExtensionPoint.eventTopics(
            extensionPointNames,
          ),
        )
      ->Belt.Array.partition(((service, _)) =>
          service == Util_DynamoDbStream.service
        );

    Js.log2(
      __MODULE__ ++ ".make: dynamoDbStreamTopics:",
      dynamoDbStreamTopics,
    );
    Js.log2(__MODULE__ ++ ".make: otherTopics:", otherTopics);

    let eventSourceMappings =
      dynamoDbStreamTopics->Belt.Array.map((_, (sourceName, source)) => {
        Js.log(
          __MODULE__
          ++ {j|.make: eventSourceMapping: sourceName=$sourceName, aggregateNames=$aggregateNames|j},
        );
        Util_EventSourceMapping.subscribe(
          ~lambda=eventHandlerLambda,
          ~targetName=name,
          ~sourceName,
          ~source,
          ~opts,
        );
      });
    Js.log2(__MODULE__ ++ ".make: eventSourceMappings:", eventSourceMappings);

    if (otherTopics->Belt.Array.length > 0) {
      let errorTopics =
        otherTopics
        ->Belt.Array.map(((service, (sourceName, _))) =>
            {j|EventTopicPublisher_$service $sourceName|j}
          )
        ->Js.Array2.joinWith(",");
      Js.Exn.raiseError(__MODULE__ ++ {j| cannot connect to $errorTopics|j});
    } else {
      {resource: None};
    };
  };
