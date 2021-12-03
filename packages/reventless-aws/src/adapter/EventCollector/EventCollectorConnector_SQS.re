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
            ~visibilityTimeoutSeconds=timeout->Pulumi.Input.wrap,
            ~redrivePolicy=
              Util_DeadLetterQueue.queue##arn
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

    let (snsTopics, otherTopics) =
      resources
      ->Reventless.Util.Aggregate.eventTopics(aggregateNames)
      ->Belt.Array.concat(
          resources->Reventless.Util.ExtensionPoint.eventTopics(
            extensionPointNames,
          ),
        )
      ->Belt.Array.partition(((service, _)) => service == Util_SNS.service);

    let _snsTopicSubscriptions =
      snsTopics->Belt.Array.map(
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
      resource: Some(queue->Util_SQS.toResource),
      enqueueEvent: queue->EventCollectorConnector_SQS_Runtime.enqueueEvent,
    };
  };
