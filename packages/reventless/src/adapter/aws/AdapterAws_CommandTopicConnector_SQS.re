open PulumiAws;

let make = (~name, ~handleCommands, ~memorySize, ~timeout, ~opts) => {
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

  let name = name ++ "Handler";

  let handler =
    Lambda.CallbackFunction.(
      make(
        ~name=name ++ "Lambda",
        ~args=
          Args.make(
            ~callback=
              AdapterAws_CommandTopicConnector_SQS_Runtime.handleQueueEvent(
                handleCommands,
                queue,
              ),
            ~policies=[|
              SQS.QueuePolicy.amazonSQSFullAccess,
              Lambda.Policy.awsLambdaFullAccess,
            |],
            ~memorySize,
            ~timeout,
            (),
          ),
        ~opts,
        (),
      )
    );

  let _queueSubscription =
    queue->SQS.Queue.onEvent(~name, ~handler, ~opts, ());

  CommandTopic.{
    resource: queue->AdapterAws_Util_SQS.toResource,
    publish: queue->AdapterAws_CommandTopicConnector_SQS_Runtime.publish,
  };
};