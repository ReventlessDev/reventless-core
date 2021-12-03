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
      );

    let _queueSubscription =
      queue->SQS.Queue.onEvent(~name, ~handler=eventHandlerLambda, ~opts, ());

    let (snsFifoTopics, otherTopics) =
      resources
      ->Reventless.Util.Aggregate.eventTopics(aggregateNames)
      ->Belt.Array.concat(
          resources->Reventless.Util.ExtensionPoint.eventTopics(
            extensionPointNames,
          ),
        )
      ->Belt.Array.partition(((service, _)) =>
          service == Util_SNS_FIFO.service
        );

    let _snsTopicSubscriptions =
      snsFifoTopics->Belt.Array.map(
        Util_SQS.subscribeToSnsTopic(queue, name, opts),
      );

    let _eventSourceMappings: array(EventSourceMapping.t) =
      otherTopics->Belt.Array.map(((_, (sourceName, source))) =>
        Util_EventSourceMapping.subscribe(
          ~lambda=eventHandlerLambda->Pulumi.Output.make,
          ~targetName=name,
          ~sourceName,
          ~source,
          ~opts,
          (),
        )
      );

    {
      resource: Some(queue->Util_SQS_FIFO.toResource),
      enqueueEvent:
        queue->EventCollectorConnector_SQS_Runtime.enqueueFifoEvent,
    };
  };
