open PulumiAws;

let make: Reventless.EventCollector.Adapter.connectorMaker =
  (
    ~name,
    ~eventTopics,
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

    let (dynamoDbStreamResources, errorResources) =
      eventTopics
      ->Js.Dict.entries
      ->Belt.Array.map(((name, eventTopic)) =>
          (
            name,
            eventTopic##resources
            ->Belt.Array.getBy(resource =>
                resource##service == Util_DynamoDbStream.service
              ),
          )
        )
      ->Belt.Array.partition(((_, resource)) =>
          resource->Belt.Option.isSome
        );

    let _eventSourceMappings: array(EventSourceMapping.t) =
      dynamoDbStreamResources->Belt.Array.map(((sourceName, resource)) =>
        Util_EventSourceMapping.subscribe(
          ~batchSize=25,
          ~lambda=eventHandlerLambda,
          ~targetName=name,
          ~sourceName,
          ~source=resource->Belt.Option.getExn,
          ~opts,
          (),
        )
      );

    if (errorResources->Belt.Array.length > 0) {
      let eventTopicNames =
        errorResources
        ->Belt.Array.map(((eventTopicName, _)) => eventTopicName)
        ->Js.Array2.joinWith(",");
      Js.Exn.raiseError(
        __MODULE__ ++ {j| cannot connect to EventTopic(s) $eventTopicNames|j},
      );
    } else {
      {
        resources: [||],
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
