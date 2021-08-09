open PulumiAws;

let make: Reventless.EventCollector.Adapter.connectorMaker =
  (
    ~name,
    ~aggregateNames,
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

    let _eventSourceMappings =
      aggregateNames
      ->Belt.Array.map(aggregateName =>
          (
            aggregateName,
            aggregateName->Reventless.EventTopic.Adapter.getResource,
          )
        )
      ->Belt.Array.map(((aggregateName, stream)) =>
          EventSourceMapping.make(
            ~name=aggregateName ++ "2" ++ name,
            ~args=
              EventSourceMapping.Args.make(
                ~functionName=
                  eventHandlerLambda
                  ->Pulumi.Output.flatMap(lambda => lambda##arn)
                  ->Pulumi.Output.asInput,
                ~eventSourceArn=stream##urn->Pulumi.Output.asInput,
                ~startingPosition=`TRIM_HORIZON,
                (),
              ),
            ~opts=Some(opts),
          )
        );

    {resource: None};
  };
