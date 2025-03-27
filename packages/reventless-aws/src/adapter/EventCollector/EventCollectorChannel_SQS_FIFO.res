type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let subscribe = (
  ~name,
  ~eventTopics: dict<Reventless.EventTopic.outputs>,
  ~channel: Reventless.EventCollector_Adapter.channel<
    callbackEvent,
    'context,
    channelParts,
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

  let eventTopicResources =
    eventTopics
    ->Js.Dict.values
    ->Array.flatMap(outputs => outputs.resources)
    ->Reventless.Adapter.resourcesToUnwrappedOutput

  let attachPolicies =
    (
      eventTopicResources,
      queue.arn,
      queue.id,
      resources->Reventless.Adapter.resourcesToUnwrappedOutput,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((eventTopicResources, queueArn, queueId, resources)) => {
      let snsFifoResources =
        eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SNS.service,
          AWS.SNS_FIFO.service,
        ])
      let dynamoDbResources =
        eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDb.service,
          AWS.DynamoDbStream.service,
        ])

      let targetSnsResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SNS.service,
          AWS.SNS_FIFO.service,
        ])

      let targetDynamoDbResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDb.service,
          AWS.DynamoDbStream.service,
        ])

      let attachQueuePolicy = {
        open PulumiAws.PolicyDocument
        PulumiAws.SQS.QueuePolicy.make(
          ~name=name ++ "QueuePolicy",
          ~args={
            queueUrl: queueId->Pulumi.Input.make,
            policy: PulumiAws.PolicyDocument.make(
              ~id=name ++ "QueuePolicy",
              ~statements=[
                {
                  sid: "AllowReceiveEvents",
                  principal: Principals({
                    service: PrincipalIds([
                      AWS.CloudwatchEventRule.principal,
                      AWS.Lambda.principal,
                      AWS.SNS.principal,
                    ]),
                  }),
                  effect: Allow,
                  actions: Actions(["sqs:SendMessage"]),
                  resources: Resource(queueArn),
                },
              ],
            )
            ->toJsonString
            ->Pulumi.Input.make,
          },
          ~opts=Some(opts),
        )
      }

      let lambdaDynamoDbStreamPolicyDocument =
        dynamoDbResources->Array.length > 0
          ? {
              open PulumiAws.PolicyDocument
              Some(
                PulumiAws.PolicyDocument.make(
                  ~id=name ++ "LambdaDynamoDbStreamPolicy",
                  ~statements=[
                    {
                      sid: "AllowLambdaToReadStream",
                      effect: Allow,
                      actions: Actions([
                        "dynamodb:DescribeStream",
                        "dynamodb:GetRecords",
                        "dynamodb:GetShardIterator",
                        "dynamodb:ListStreams",
                      ]),
                      resources: Resources(
                        dynamoDbResources->Array.map(dynamoDbResource => dynamoDbResource.name),
                      ),
                    },
                  ],
                ),
              )
            }
          : None

      let lambdaWriteDynamoDbPolicyDocument =
        targetDynamoDbResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaAllowDynamoDbWrite",
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
                      targetDynamoDbResources->Array.map(dynamoDbResource => dynamoDbResource.urn),
                    ),
                  },
                ],
              ),
            )
          : None

      let lambdaSnsPublishNotificationPolicyDocument =
        targetSnsResources->Array.length > 0
          ? {
              Some(
                PulumiAws.PolicyDocument.make(
                  ~id=name ++ "PublishSNS",
                  ~statements=[
                    {
                      sid: "LambdaAllowPublishSNS",
                      effect: Allow,
                      actions: Action("sns:Publish"),
                      resources: Resources(
                        targetSnsResources->Array.map(snsResource => snsResource.urn),
                      ),
                    },
                  ],
                ),
              )
            }
          : None

      let lambdaQueuePolicyDocument = {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "SQSLambdaPolicy",
          ~statements=[
            {
              sid: "AllowLambdaReceiveSQSMessage",
              effect: Allow,
              actions: Actions([
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
              ]),
              resources: Resource(queueArn),
            },
          ],
        )
      }

      let attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              Some(lambdaQueuePolicyDocument),
              lambdaDynamoDbStreamPolicyDocument,
              lambdaWriteDynamoDbPolicyDocument,
              lambdaSnsPublishNotificationPolicyDocument,
            ]->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _snsFifoTopicSubscriptions =
        snsFifoResources->Array.map(snsFifoResource =>
          Util_SQS.subscribeToSnsTopic(
            ~queue,
            ~targetName=name,
            ~sourceName=snsFifoResource.name,
            ~topic=snsFifoResource->Reventless.AdapterDeploytime.unwrappedToResource,
            ~opts,
          )
        )

      let _eventSourceMappings =
        dynamoDbResources->Array.map(dynamoDbResource =>
          Util_EventSourceMapping.subscribe(
            ~lambda,
            ~targetName=name,
            ~sourceName=dynamoDbResource.name,
            ~source=dynamoDbResource->Reventless.AdapterDeploytime.unwrappedToResource,
            ~opts,
          )
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

let make: Reventless.EventCollector_Adapter.channelMaker<
  callbackEvent,
  'context,
  channelParts,
  runtimeParts,
> = (~name, ~opts) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let queue = PulumiAws.SQS.Queue.make(
    ~name,
    ~args={
      PulumiAws.SQS.Queue.fifoQueue: true->Pulumi.Input.make,
      deduplicationScope: MessageGroup,
      fifoThroughputLimit: PerMessageGroupId,
      contentBasedDeduplication: true->Pulumi.Input.make,
      visibilityTimeoutSeconds: 30->Pulumi.Input.make, // TODO fix timeout
      redrivePolicy: Util_DeadLetterQueue.fifoQueue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.Tags.make(~name, Reventless.EventCollector.componentType),
    },
    ~opts,
  )

  {
    Reventless.EventCollector_Adapter.parts: {queue: queue},
    resources: [queue->Util_SQS_FIFO.toResource],
    enqueueEvent: queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
    ),
    subscribe,
    handleChannelEvent: handleEvents =>
      queue
      ->Util_SQS.toRuntimeQueueOutput
      ->Pulumi.Output.apply(runtimeQueue =>
        runtimeQueue->(
          EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(handleEvents, ...)
        )
      ),
  }
}
