type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = unit
type runtimeParts = Util.Lambda.runtimeParts

let connect = (
  ~name,
  ~eventTopics: dict<Reventless.EventTopic.outputs>,
  ~channel as _,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~resources: array<ReventlessSpec.Adapter.resource>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let eventTopicResources =
    eventTopics
    ->Js.Dict.values
    ->Array.flatMap(outputs => outputs.resources)
    ->Reventless.Adapter.resourcesToUnwrappedOutput

  let _ =
    (eventTopicResources, resources->Reventless.Adapter.resourcesToUnwrappedOutput)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventTopicResources, resources)) => {
      open PulumiAws.PolicyDocument
      open Reventless.Adapter

      // Js.Console.log3(
      //   `EventCollectorChannel_DynamoDbStream: EventTopicResources for ${name}:`,
      //   eventTopicResources,
      // )
      // Js.Console.log3(`EventCollectorChannel_DynamoDbStream: Resources for" ${name}:`, resources)

      let dynamoDbStreamResources =
        eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDbStream.service,
        ])
      let targetDynamoDbResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.DynamoDb.service,
          AWS.DynamoDbStream.service,
        ])
      let targetSqsResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SQS.service,
          AWS.SQS_FIFO.service,
        ])
      let targetSnsResources =
        resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
          AWS.SNS.service,
          AWS.SNS_FIFO.service,
        ])

      let streamSourcesWithPolicy =
        dynamoDbStreamResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "Policy",
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

      let _attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              streamSourcesWithPolicy,
              lambdaWriteDynamoDbPolicyDocument,
              lambdaSnsPublishNotificationPolicyDocument,
              lambdaSqsSendPolicyDocument,
            ]->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )

      let _subscribeEventStreams = dynamoDbStreamResources->Array.map(dynamoDbStreamResource => {
        Util_EventSourceMapping.subscribe(
          ~batchSize=25,
          ~lambda,
          ~targetName=name,
          ~sourceName=dynamoDbStreamResource.name,
          ~source=dynamoDbStreamResource->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
      })
    })

  []
}

let make: Reventless.EventCollector_Adapter.channelMaker<
  callbackEvent,
  'context,
  unit,
  runtimeParts,
> = (~name as _, ~eventTopics, ~opts as _) => {
  let eventTopicResources =
    eventTopics
    ->Js.Dict.values
    ->Array.map(outputs => outputs.resources->Array.getUnsafe(0)) // FIXME

  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Js.log4(__MODULE__ ++ " supports no enqueueEvent:", delay, id, messageBody)->Js.Promise.resolve

  let handleChannelEvent = handleEvents =>
    (EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...))->Pulumi.Output.make

  {
    Reventless.EventCollector_Adapter.parts: (),
    resources: eventTopicResources,
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    connect,
    handleChannelEvent,
  }
}
