type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = Util.SQS.channelParts
type runtimeParts = Util.Lambda.runtimeParts

let connect = (
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

  let _ =
    (
      eventTopicResources,
      queue.arn,
      queue.id,
      resources->Reventless.Adapter.resourcesToUnwrappedOutput,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((eventTopicResources, queueArn, queueId, resources)) => {
      open PulumiAws.PolicyDocument
      open Reventless.Adapter

      Js.Console.log3(
        "EventCollectorChannel_SQS: EventTopicResources for ",
        name ++ ": ",
        eventTopicResources,
      )
      Js.Console.log3("EventCollectorChannel_SQS: Resources for ", name ++ ": ", resources)

      let snsResources =
        eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SNS.service,
        ])
      let dynamoDbStreamResources =
        eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDbStream.service,
        ])
      let targetSnsResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SNS.service,
          AWS.SNS_FIFO.service,
        ])
      let targetSqsResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SQS.service,
          AWS.SQS_FIFO.service,
        ])
      let targetDynamoDbResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDb.service,
          AWS.DynamoDbStream.service,
        ])

      let _attachQueuePolicy = {
        PulumiAws.SQS.QueuePolicy.make(
          ~name=name ++ "QueuePolicy",
          ~args={
            queueUrl: queueId->Pulumi.Input.make,
            policy: PulumiAws.PolicyDocument.make(
              ~id=name ++ "QueuePolicy",
              ~statements=[
                {
                  sid: "AllowReceiveSnsEvents",
                  principal: Principals({
                    service: PrincipalIds([AWS.SNS.principal]),
                  }),
                  effect: Allow,
                  actions: Actions(["sqs:SendMessage"]),
                  resources: Resource(queueArn),
                  conditions: {
                    arnEquals: [
                      ("aws:SourceArn", ConditionValues(snsResources->urns)),
                    ]->Js.Dict.fromArray,
                  },
                },
              ],
            )
            ->toJsonString
            ->Pulumi.Input.make,
          },
          ~opts=Some(opts),
        )
      }

      let lambdaDynamoDbStreamPolicyDocuments =
        dynamoDbStreamResources->Array.length > 0
          ? {
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
                      resources: Resources(dynamoDbStreamResources->urns),
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
                    resources: Resources(targetDynamoDbResources->urns),
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
                      resources: Resources(targetSnsResources->urns),
                    },
                  ],
                ),
              )
            }
          : None

      let lambdaSqsSendPolicyDocument =
        targetSqsResources->Array.length > 0
          ? {
              Some(
                PulumiAws.PolicyDocument.make(
                  ~id=name ++ "SendSQS",
                  ~statements=[
                    {
                      sid: "LambdaAllowSendSQS",
                      effect: Allow,
                      actions: Action("sqs:SendMessage"),
                      resources: Resources(targetSqsResources->urns),
                    },
                  ],
                ),
              )
            }
          : None

      let lambdaQueuePolicyDocument = {
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "LambdaSQSPolicy",
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

      let _attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              Some(lambdaQueuePolicyDocument),
              lambdaDynamoDbStreamPolicyDocuments,
              lambdaWriteDynamoDbPolicyDocument,
              lambdaSnsPublishNotificationPolicyDocument,
              lambdaSqsSendPolicyDocument,
            ]->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _snsTopicSubscriptions = snsResources->Array.map(snsFifoResource => {
        Js.log2("EventCollectorChannel_SQS: subscribeToSnsTopic:", snsFifoResource)
        let subscription = Util_SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName=snsFifoResource.name,
          ~topic=snsFifoResource->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
        subscription.id->Pulumi.Output.apply(
          id => Js.log3("EventCollectorChannel_SQS: created SNS subscription:", id, name),
        )
      })

      let _printWarningForEmptySnsTopic = if snsResources->Array.length == 0 {
        Js.Console.warn2("No SNS topics are present for EventCollectorChannel ", name)
      }

      let _eventSourceMappings =
        dynamoDbStreamResources->Array.map(dynamoDbStreamResource =>
          Util_EventSourceMapping.subscribe(
            ~lambda,
            ~targetName=name,
            ~sourceName=dynamoDbStreamResource.name,
            ~source=dynamoDbStreamResource->Reventless.AdapterDeploytime.unwrappedToResource,
            ~opts,
          )
        )
    })

  let resource =
    lambda
    ->Pulumi.Output.apply(lambda => {
      queue
      ->PulumiAws.SQS.Queue.onEvent(~name, ~handler=lambda, ~opts)
      ->Util.SQS.Subscription.toResource
    })
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
      PulumiAws.SQS.Queue.visibilityTimeoutSeconds: 120->Pulumi.Input.make,
      redrivePolicy: Util_DeadLetterQueue.queue.arn
      ->Pulumi.Output.apply(dlqArn =>
        PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5)
      )
      ->Pulumi.Output.asInput,
      sqsManagedSseEnabled: false->Pulumi.Input.make,
      tags: AWS.Tags.make(~name, Reventless.EventCollector.componentType),
    },
    ~opts,
  )

  let enqueueEvent =
    queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      EventCollectorChannel_SQS_Runtime.enqueueEvent(runtimeQueue, ...)
    )

  let handleChannelEvent = handleEvents =>
    queue
    ->Util_SQS.toRuntimeQueueOutput
    ->Pulumi.Output.apply(runtimeQueue =>
      runtimeQueue->(EventCollectorChannel_SQS_Runtime.handleDynamoDbOrSqsEvent(handleEvents, ...))
    )

  {
    Reventless.EventCollector_Adapter.parts: {queue: queue},
    resources: [queue->Util_SQS.toResource],
    enqueueEvent,
    connect,
    handleChannelEvent,
  }
}
