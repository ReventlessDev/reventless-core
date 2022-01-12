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
    let queue =
      SQS.Queue.make(
        ~name,
        ~args=
          SQS.Queue.Args.make(
            ~fifoQueue=true->Pulumi.Input.wrap,
            ~deduplicationScope=`messageGroup,
            ~fifoThroughputLimit=`perMessageGroupId,
            ~contentBasedDeduplication=true->Pulumi.Input.wrap,
            ~visibilityTimeoutSeconds=timeout->Pulumi.Input.wrap,
            ~redrivePolicy=
              Util_DeadLetterQueue.fifoQueue##arn
              ->Pulumi.Output.apply(dlqArn =>
                  SQS.Queue.Args.RedrivePolicy.make(
                    ~deadLetterTargetArn=dlqArn,
                    ~maxReceiveCount=5,
                  )
                )
              ->Pulumi.Output.asInput,
            (),
          ),
        ~opts,
        (),
      );

    let _queuePolicy =
      Util_SqsQueuePolicy.(
        make(
          ~name,
          ~queue,
          ~statements=[|
            allowAllSnsTopicsSendMessage(queue),
            allowCloudWatchEvents,
          |],
          ~opts,
          (),
        )
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
                  EventCollectorConnector_SQS_Runtime.handleCallbackEvent(
                    handleEvents,
                    queue,
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

    let _queueSubscription =
      // Pulumi.Output cannot be pushed into handler parameter !
      eventHandlerLambda->Pulumi.Output.apply(eventHandlerLambda =>
        queue->SQS.Queue.onEvent(
          ~name,
          ~handler=eventHandlerLambda,
          ~opts,
          (),
        )
      );

    let (supportedResources, errorResources) =
      eventTopics
      ->Js.Dict.entries
      ->Belt.Array.map(((name, eventTopic)) =>
          (
            name,
            eventTopic##resources
            ->Belt.Array.getBy(resource =>
                resource##service == Util_DynamoDbStream.service
                ||
                resource##service == Util_SNS_FIFO.service
              ),
          )
        )
      ->Belt.Array.partition(((_, resource)) =>
          resource->Belt.Option.isSome
        );

    let (snsFifoResources, otherResources) =
      supportedResources->Belt.Array.partition(((_, resource)) =>
        resource->Belt.Option.getExn##service == Util_SNS_FIFO.service
      );

    let _snsTopicSubscriptions =
      snsFifoResources->Belt.Array.map(((sourceName, resource)) =>
        Util_SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName,
          ~topic=resource->Belt.Option.getExn,
          ~opts,
        )
      );

    let _eventSourceMappings =
      otherResources->Belt.Array.map(((sourceName, resource)) =>
        Util_EventSourceMapping.subscribe(
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
        resources: [|queue->Util_SQS_FIFO.toResource|],
        enqueueEvent:
          queue->EventCollectorConnector_SQS_Runtime.enqueueFifoEvent,
      };
    };
  };
