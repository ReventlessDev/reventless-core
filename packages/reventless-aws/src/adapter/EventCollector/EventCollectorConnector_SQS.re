open PulumiAws;

let make: Reventless.EventCollector.connectorMaker =
  (
    ~name,
    ~eventServices,
    ~queryEventTopic: Reventless.InterstackResourceQuery.deploytimeQueryExn,
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
            ~visibilityTimeoutSeconds=timeout->Pulumi.Input.wrap,
            ~redrivePolicy=
              Util_DeadLetterQueue.queue##arn
              ->Pulumi.Output.apply(dlqArn =>
                  SQS.Queue.Args.RedrivePolicy.make(
                    ~deadLetterTargetArn=dlqArn,
                    ~maxReceiveCount=3,
                  )
                )
              ->Pulumi.Output.asInput,
            (),
          ),
        ~opts,
        (),
      );

    let serviceNamesAndTopics =
      eventServices->Belt.Array.map(eventService =>
        (eventService, queryEventTopic(eventService))
      );

    let _topicSubscriptions =
      serviceNamesAndTopics->Belt.Array.map(((eventService, topic)) =>
        SNS.TopicSubscription.make(
          ~name=eventService ++ "2" ++ name,
          ~args=
            SNS.TopicSubscription.Args.make(
              ~endpoint=queue##arn->Pulumi.Output.asInput,
              ~protocol=`sqs,
              ~topic=
                topic
                ->Pulumi.Output.flatMap(topic => topic##urn)
                ->Pulumi.Output.asInput,
              ~rawMessageDelivery=true->Pulumi.Input.wrap,
              (),
            ),
          ~opts=Some(opts),
        )
      );

    let _topics = serviceNamesAndTopics->Belt.Array.map(snd);

    let _queuePolicy =
      Util.SqsQueuePolicy.(
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

    {Reventless.EventCollector.resource: queue->Util_SQS.toResource};
  };
