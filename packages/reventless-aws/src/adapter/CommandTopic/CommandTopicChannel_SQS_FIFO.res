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
    ->Util.SQS_FIFO.findResource
    ->Util.SQS_FIFO.fromResource

  let handler =
    runtime.resources
    ->Util.Lambda.findResource
    ->Util.Lambda.fromResource

  let handlerRole = runtime.resources->Util.IAM_Role.findResource->Util.IAM_Role.fromResource

  let _attachPolicies =
    (
      queue->Pulumi.Output.flatMap(queue => queue.arn),
      handler->Pulumi.Output.flatMap(handler => handler.arn),
      handler->Pulumi.Output.flatMap(handler => handler.name),
      handlerRole,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((queueArn, handlerArn, handlerName, handlerRole)) => {
      open PulumiAws.PolicyDocument

      let queuePolicyDocument =
        PulumiAws.PolicyDocument.make(
          ~statements=[
            {
              sid: "AllowLambdaToPublish",
              principal: Principals({
                service: PrincipalId(AWS.Lambda.principal),
              }),
              effect: Allow,
              actions: Actions(["sqs:SendMessage"]),
              resources: Resource(handlerArn),
              conditions: {
                arnEquals: Js.Dict.fromArray([("AWS:SourceArn", ConditionValue(handlerName))]),
              },
            },
            {
              sid: "AllowCloudWatchEvents",
              effect: Allow,
              actions: Actions(["sqs:SendMessage"]),
              resources: Resource(queueArn),
              principal: Principals({
                service: PrincipalId(AWS.CloudwatchEventRule.principal),
              }),
            },
          ],
        )
        ->toJsonString
        ->Pulumi.Input.make

      let allowSQSLambdaPolicyDocument = PulumiAws.PolicyDocument.make(
        ~statements=[
          {
            sid: "AllowSQSReceiveMessage",
            effect: Allow,
            actions: Actions(["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]),
            resources: Resource(queueArn),
          },
        ],
      )

      let lambdaPolicy = PulumiAws.IAM.Policy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments([
            PulumiAws.Lambda.defaultLoggingPolicyDocument,
            allowSQSLambdaPolicyDocument,
          ])->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _attachLambdaPolicy = PulumiAws.IAM.RolePolicyAttachment.make(
        ~name,
        ~args={
          policyArn: lambdaPolicy.arn->Pulumi.Output.asInput,
          role: handlerRole.arn->Pulumi.Output.asInput,
        },
        ~opts=Some(opts),
      )
      let _attachQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
        ~name,
        ~args={queueUrl: queueArn->Pulumi.Input.make, policy: queuePolicyDocument},
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
      PulumiAws.SQS.Queue.fifoQueue: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: (6 * 30)->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
      ->Pulumi.Output.apply(dlqArn => {
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      })
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
      tags: AWS.Tags.make(~name, Reventless.CommandTopic.componentType),
    },
    ~opts?,
  )

  {
    resources: [queue->Util_SQS_FIFO.toResource],
    publishJsons: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS_FIFO, ...))
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
