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

    let _eventSourceMappings: array(EventSourceMapping.t) =
      dynamoDbStreamTopics->Belt.Array.map(((_, (sourceName, source))) =>
        Util_EventSourceMapping.subscribe(
          ~batchSize=25,
          ~lambda=eventHandlerLambda,
          ~targetName=name,
          ~sourceName,
          ~source,
          ~opts,
          (),
        )
      );

    if (otherTopics->Belt.Array.length > 0) {
      let errorTopics =
        otherTopics
        ->Belt.Array.map(((service, (sourceName, _))) =>
            {j|EventTopicPublisher_$service $sourceName|j}
          )
        ->Js.Array2.joinWith(",");
      Js.Exn.raiseError(__MODULE__ ++ {j| cannot connect to $errorTopics|j});
    } else {
      {
        resource: None,
        enqueueEvent:
          (. delay, id, messageBody) =>
            // TODO: can we check this at deploy time ?
            Js.log4(
              __MODULE__ ++ " supports no enqueueEvent:",
              delay,
              id,
              messageBody,
            )
            ->Js.Promise.resolve,
      };
    };
  };
