open PulumiAws;

let make =
    (
      ~name,
      ~eventServices,
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
      ~policies,
      ~handleEvents,
      ~memorySize,
      ~timeout,
      ~opts,
    ) => {
  let queueName = name ++ "Queue";

  let queue =
    SQS.Queue.make(
      ~name=queueName,
      ~args=
        SQS.Queue.Args.make(
          ~visibilityTimeoutSeconds=timeout,
          ~redrivePolicy=
            AdapterAws_Util_DeadLetterQueue.queue##arn
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
        ~name=eventService ++ "2" ++ queueName ++ "TopicSubscription",
        ~args=
          SNS.TopicSubscription.Args.make(
            ~endpoint=queue##arn->Pulumi.Output.asInput,
            ~protocol=`sqs,
            ~topic=
              topic
              ->Pulumi.Output.flatMap(topic => topic##urn)
              ->Pulumi.Output.asInput,
            ~rawMessageDelivery=true,
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
        AdapterAws_Util.SqsQueuePolicy.(
          make(
            ~name=queueName ++ "Policy",
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
          ~name=name ++ "Lambda",
          ~args=
            Lambda.CallbackFunction.Args.make(
              ~callback=
                AdapterAws_EventCollectorConnector_SQS_Runtime.handleQueueEvent(
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

  {EventCollector.resource: queue->AdapterAws_Util_SQS.toResource};
};