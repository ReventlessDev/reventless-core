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
    (queue, handler, handlerRole)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((queue, handler, handlerRole)) => {
      open PulumiAws

      let queuePolicyDocument =
        PolicyDocument.make(
          ~statements=[
            {
              principal: PolicyDocument.Principals({
                service: PolicyDocument.PrincipalId(AWS.Lambda.principal),
              }),
              effect: PolicyDocument.Allow,
              actions: PolicyDocument.Actions(["sqs:SendMessage"]),
              resources: PolicyDocument.Resource(handler.arn->Pulumi.Output.unwrap),
              conditions: {
                arnEquals: Js.Dict.fromArray([
                  (
                    "AWS:SourceArn",
                    PolicyDocument.ConditionValue(handler.name->Pulumi.Output.unwrap),
                  ),
                ]),
              },
            },
          ],
        )
        ->PolicyDocument.toJsonString
        ->Pulumi.Input.make

      let allowSQSLambdaPolicyDocument = PolicyDocument.make(
        ~statements=[
          {
            effect: PolicyDocument.Allow,
            actions: PolicyDocument.Actions([
              "sqs:ReceiveMessage",
              "sqs:DeleteMessage",
              "sqs:GetQueueAttributes",
            ]),
            resources: PolicyDocument.Resource(queue.arn->Pulumi.Output.unwrap),
          },
        ],
      )

      let lambdaPolicy = IAM.Policy.make(
        ~name,
        ~args={
          policy: PolicyDocument.mergePolicyDocuments(
            ~policyDocuments=[Lambda.defaultLoggingPolicyDocument, allowSQSLambdaPolicyDocument],
          )->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _attachLambdaPolicy = IAM.RolePolicyAttachment.make(
        ~name,
        ~args={
          policyArn: lambdaPolicy.arn->Pulumi.Output.asInput,
          role: handlerRole.arn->Pulumi.Output.asInput,
        },
        ~opts=Some(opts),
      )
      let _attachQueuePolicy = SQS.QueuePolicy.make(
        ~name,
        ~args={queueUrl: queue.arn->Pulumi.Output.asInput, policy: queuePolicyDocument},
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

  /* let _queuePolicy = {
    open Util_SqsQueuePolicy
    make(~name, ~queue, ~statements=[allowCloudWatchEvents], ~opts?)
  }*/

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
