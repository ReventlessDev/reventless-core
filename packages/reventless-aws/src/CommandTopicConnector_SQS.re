open PulumiAws;

let make: Reventless.CommandTopic.connectorMaker =
  (~name, ~handleCommands, ~memorySize, ~timeout, ~opts) => {
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

    let _queuePolicy =
      Util.SqsQueuePolicy.(
        make(~name, ~queue, ~statements=[|allowCloudWatchEvents|], ~opts, ())
      );

    let name = name ++ "Handler";

    let handler =
      Lambda.CallbackFunction.(
        make(
          ~name,
          ~args=
            Args.make(
              ~callback=
                CommandTopicConnector_SQS_Runtime.handleQueueEvent(
                  handleCommands,
                  queue,
                ),
              ~policies=[|
                SQS.QueuePolicy.amazonSQSFullAccess,
                Lambda.Policy.awsLambdaFullAccess,
              |],
              ~memorySize=memorySize->Pulumi.Input.wrap,
              ~timeout=timeout->Pulumi.Input.wrap,
              (),
            ),
          ~opts,
          (),
        )
      );

    let _queueSubscription =
      queue->SQS.Queue.onEvent(~name, ~handler, ~opts, ());

    Reventless.CommandTopic.{
      resource: queue->Util_SQS.toResource,
      publish: queue->CommandTopicConnector_SQS_Runtime.publish,
    };
  };
