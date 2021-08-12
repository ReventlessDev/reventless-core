open PulumiAws;

let make: Reventless.CommandTopic.Adapter.connectorMaker =
  (~name, ~handleCommands, ~memorySize, ~timeout, ~opts, ~resources as _) => {
    let queue =
      SQS.Queue.make(
        ~name,
        ~args=
          SQS.Queue.Args.make(
            ~visibilityTimeoutSeconds=(6 * timeout)->Pulumi.Input.wrap,
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
        make(~name, ~queue, ~statements=[|allowCloudWatchEvents|], ~opts, ())
      );

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
              ~policies=Lambda.Policy.defaultPolicies,
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

    {
      resource: queue->Util_SQS.toResource,
      publish: queue->CommandTopicConnector_SQS_Runtime.publish,
    };
  };
