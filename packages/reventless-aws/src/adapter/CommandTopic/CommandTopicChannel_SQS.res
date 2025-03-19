type callbackEvent = PulumiAws.SQS.Queue.event

let subscribe = (
  ~name,
  ~channel: Reventless.CommandTopic_Adapter.channel<callbackEvent, 'context>,
  ~runtime: Reventless.Runtime.environment,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue =
    channel.resources
    ->Util.SQS.findResource
    ->Util.SQS.fromResource

  let handler =
    runtime.resources
    ->Util.Lambda.findResource
    ->Util.Lambda.fromResource

  let handlerRole = runtime.resources->Util.IAM_Role.findResource->Util.IAM_Role.fromResource

  let _attachPolicies =
    (
      queue->Pulumi.Output.flatMap(queue => queue.arn),
      queue->Pulumi.Output.flatMap(queue => queue.id),
      handler->Pulumi.Output.flatMap(handler => handler.arn),
      handlerRole,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((queueArn, queueId, handlerArn, handlerRole)) => {
      open PulumiAws.PolicyDocument

      let queuePolicyDocument =
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "QueuePolicy",
          ~statements=[
            {
              sid: "AllowLambdaToAccessQueue",
              effect: Allow,
              principal: Principals({
                service: PrincipalId("lambda.amazonaws.com"),
              }),
              actions: Actions([
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
              ]),
              resources: Resource(queueArn),
              conditions: {
                arnEquals: Js.Dict.fromArray([("AWS:SourceArn", ConditionValue(handlerArn))]),
              },
            },
            {
              sid: "AllowCloudWatchEventsToSendToQueue",
              effect: Allow,
              principal: Principals({
                service: PrincipalId("events.amazonaws.com"),
              }),
              actions: Actions(["sqs:SendMessage"]),
              resources: Resource(queueArn),
            },
          ],
        )
        ->toJsonString
        ->Pulumi.Input.make

      let allowSQSLambdaPolicyDocument = PulumiAws.PolicyDocument.make(
        ~id=name ++ "SQSLambdaPolicy",
        ~statements=[
          {
            sid: "AllowLambdaSendAndReceiveMessage",
            effect: Allow,
            actions: Actions([
              "sqs:ReceiveMessage",
              "sqs:DeleteMessage",
              "sqs:GetQueueAttributes",
              "sqs:ChangeMessageVisibility",
            ]),
            resources: Resource(queueArn),
          },
        ],
      )

      let _attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [PulumiAws.Lambda.defaultLoggingPolicyDocument, allowSQSLambdaPolicyDocument],
          )->Pulumi.Output.asInput,
          role: handlerRole.id->Pulumi.Output.asInput
        },
        ~opts,
      )

      let _attachQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
        ~name,
        ~args={queueUrl: queueId->Pulumi.Input.make, policy: queuePolicyDocument},
        ~opts=Some(opts),
      )
    })

  let resource =
    (queue, handler)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queue, handler)) =>
      queue->PulumiAws.SQS.Queue.onEvent(~name, ~handler, ~opts)->Util.SQS.Subscription.toResource
    )
    ->Reventless.Adapter.outputToResource
  [resource]
}

let make: Reventless.CommandTopic_Adapter.channelMaker<callbackEvent, 'context> = (
  ~name,
  ~opts=?,
) => {
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make, // TODO rethink timeout
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.Tags.make(~name, Reventless.CommandTopic.componentType),
    },
    ~opts?,
  )

  {
    Reventless.CommandTopic_Adapter.resources: [queue->Util_SQS.toResource],
    publishJsons: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...))
    ),
    subscribe,
    handleChannelEvent: handleCommands =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue =>
        runtimeQueue->(CommandTopicChannel_SQS_Runtime.handleQueueEvent(handleCommands, ...))
      ),
  }
}
