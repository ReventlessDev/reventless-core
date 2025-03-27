type callbackEvent = PulumiAws.SQS.Queue.event
type runtimeParts = Util.Lambda.runtimeParts
type channelParts = Util.SQS.channelParts

let subscribe = (
  ~name,
  ~channel: Reventless.CommandTopic_Adapter.channel<
    callbackEvent,
    'context,
    Util.SQS.channelParts,
    runtimeParts,
  >,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~resources: array<ReventlessSpec.Adapter.resource>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue = channel.parts.queue
  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let attachPolicies =
    (
      queue.arn,
      queue.id,
      lambda->Pulumi.Output.flatMap(lambda => lambda.arn),
      resources->Reventless.Adapter.resourcesToUnwrappedOutput,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((queueArn, queueId, handlerArn, resources)) => {
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

      let sqsResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SQS.service,
          AWS.SQS_FIFO.service,
        ])

      let dynamoDbResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDb.service,
          AWS.DynamoDbStream.service,
        ])

      let allowSQSSendLambdaPolicyDocument =
        sqsResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "RemoteSQSLambdaPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaSendMessageSQS",
                    effect: Allow,
                    actions: Action("sqs:SendMessage"),
                    resources: Resources(sqsResources->Array.map(sqsResource => sqsResource.urn)),
                  },
                ],
              ),
            )
          : None

      let allowLambdaToAccessDynamoDb =
        dynamoDbResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaDynamoDbAccessPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaReadWriteDynamoDb",
                    effect: Allow,
                    actions: Actions([
                      "dynamodb:GetItem",
                      "dynamodb:Query",
                      "dynamodb:Scan",
                      "dynamodb:BatchGetItem",
                      "dynamodb:PutItem",
                      "dynamodb:UpdateItem",
                      "dynamodb:DeleteItem",
                      "dynamodb:BatchWriteItem",
                    ]),
                    resources: Resources(
                      dynamoDbResources->Array.map(dynamoDbResource => dynamoDbResource.urn),
                    ),
                  },
                ],
              ),
            )
          : None

      let allowLambdaToTriggerCloudWatchEvents = PulumiAws.PolicyDocument.make(
        ~id=name ++ "LambdaCloudWatchEventsPolicy",
        ~statements=[
          {
            sid: "AllowLambdaTriggerCloudWatchEvents",
            effect: Allow,
            actions: Actions([
              "events:PutRule",
              "events:PutTargets",
              "events:DeleteRule",
              "events:RemoveTargets",
            ]),
            resources: Resource("*"),
          },
        ],
      )

      let allowSQSLambdaPolicyDocument = PulumiAws.PolicyDocument.make(
        ~id=name ++ "SQSLambdaPolicy",
        ~statements=[
          {
            sid: "AllowLambdaReceiveMessage",
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

      let allowLambdaPassRoleToEvents = PulumiAws.PolicyDocument.make(
        ~id=name ++ "LambdaPassRoleToCloudWatchEventsRule",
        ~statements=[
          {
            sid: "AllowLambdaPassRoleToEvents",
            effect: Allow,
            actions: Action("iam:PassRole"),
            resources: Resource("*"),
            conditions: {
              stringEquals: Js.Dict.fromArray([
                ("iam:PassedToService", ConditionValue("events.amazonaws.com")),
              ]),
            },
          },
        ],
      )

      let attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              Some(allowSQSLambdaPolicyDocument),
              Some(allowLambdaToTriggerCloudWatchEvents),
              Some(allowLambdaPassRoleToEvents),
              allowLambdaToAccessDynamoDb,
              allowSQSSendLambdaPolicyDocument,
            ]->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let attachQueuePolicy = PulumiAws.SQS.QueuePolicy.make(
        ~name,
        ~args={queueUrl: queueId->Pulumi.Input.make, policy: queuePolicyDocument},
        ~opts=Some(opts),
      )

      (attachLambdaPolicy, attachQueuePolicy)
    })

  let resource =
    attachPolicies
    ->Pulumi.Output.flatMap(((attachLambdaPolicy, attachQueuePolicy)) =>
      (attachLambdaPolicy.id, attachQueuePolicy.id, lambda)
      ->Pulumi.Output.all3
      ->Pulumi.Output.apply(((_, _, lambda)) => {
        queue
        ->PulumiAws.SQS.Queue.onEvent(~name, ~handler=lambda, ~opts)
        ->Util.SQS.Subscription.toResource
      })
    )
    ->Reventless.Adapter.outputToResource

  [resource]
}

let make: Reventless.CommandTopic_Adapter.channelMaker<
  callbackEvent,
  'context,
  Util.SQS.channelParts,
  Util.Lambda.runtimeParts,
> = (~name, ~opts=?) => {
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
    Reventless.CommandTopic_Adapter.parts: {queue: queue},
    resources: [queue->Util_SQS.toResource],
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
