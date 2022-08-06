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

    eventTopics
    ->Util.Adapter.partitionSupportedResources([|
        Util_DynamoDbStream.service,
        Util_SNS_FIFO.service,
      |])
    ->Pulumi.Output.apply(((dynamoDbStreamResources, errorResources)) => {
        let _eventSourceMappings: array(EventSourceMapping.t) =
          dynamoDbStreamResources->Belt.Array.map(((sourceName, source)) =>
            Util_EventSourceMapping.subscribe(
              ~batchSize=25,
              ~lambda=eventHandlerLambda,
              ~targetName=name,
              ~sourceName,
              ~source=source->Reventless.Adapter.toResource,
              ~opts,
              (),
            )
          );

        if (errorResources->Belt.Array.length > 0) {
          let eventTopicNames = errorResources->Js.Array2.joinWith(",");
          Js.Exn.raiseError(
            __MODULE__
            ++ {j| cannot connect to EventTopic(s) $eventTopicNames|j},
          );
        } else {
          {
            Reventless.EventCollector.Adapter.resources: [||],
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
      });
  };
