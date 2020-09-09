open PulumiAws;

let make =
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
          ~visibilityTimeoutSeconds=timeout,
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

  let topics = serviceNamesAndTopics->Belt.Array.map(snd);
  let _queuePolicy =
    topics
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(topics =>
        Util.SqsQueuePolicy.(
          make(
            ~name,
            ~queue,
            ~statements=[
              allowResources(~queue, ~resources=topics),
              allowCloudWatchEvents,
            ],
            ~opts,
            (),
          )
        )
      );

  let eventHandlerLambda =
    policies
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
              ~memorySize,
              ~timeout,
              (),
            ),
          ~opts,
          (),
        )
      );

  let _queueSubscription =
    eventHandlerLambda->Pulumi.Output.apply(eventHandlerLambda =>
      queue->SQS.Queue.onEvent(~name, ~handler=eventHandlerLambda, ~opts, ())
    );

  {Reventless.EventCollector.resource: queue->Util_SQS.toResource};
};
