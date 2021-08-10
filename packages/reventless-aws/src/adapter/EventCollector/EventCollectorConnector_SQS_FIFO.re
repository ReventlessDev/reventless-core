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
                  EventCollectorConnector_SQS_Runtime.handleQueueEvent(
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

    let (snsFifoTopics, otherTopics) =
      aggregateNames
      ->Belt.Array.map(aggregateName =>
          (
            aggregateName,
            aggregateName->Reventless.EventTopic.Adapter.getResource,
          )
        )
      ->Belt.Array.map(((aggregateName, topic)) =>
          (topic##service, (aggregateName, topic))
        )
      ->Belt.Array.partition(((service, _)) =>
          service == Util_SNS_FIFO.service
        );

    let _snsTopicSubscriptions =
      snsFifoTopics->Belt.Array.map(((_, (aggregateName, topic))) =>
        SNS.TopicSubscription.make(
          ~name=aggregateName ++ "2" ++ name,
          ~args=
            SNS.TopicSubscription.Args.make(
              ~endpoint=queue##arn->Pulumi.Output.asInput,
              ~protocol=`sqs,
              ~topic=topic##urn->Pulumi.Output.asInput,
              ~rawMessageDelivery=true->Pulumi.Input.wrap,
              (),
            ),
          ~opts=Some(opts),
        )
      );

    let _eventSourceMappings =
      otherTopics->Belt.Array.map(((_, (aggregateName, topic))) =>
        EventSourceMapping.make(
          ~name=aggregateName ++ "2" ++ name,
          ~args=
            EventSourceMapping.Args.make(
              ~functionName=
                eventHandlerLambda
                ->Pulumi.Output.flatMap(lambda => lambda##arn)
                ->Pulumi.Output.asInput,
              ~eventSourceArn=topic##urn->Pulumi.Output.asInput,
              ~startingPosition=`TRIM_HORIZON,
              (),
            ),
          ~opts=Some(opts),
        )
      );

    {resource: Some(queue->Util_SQS_FIFO.toResource)};
  };
