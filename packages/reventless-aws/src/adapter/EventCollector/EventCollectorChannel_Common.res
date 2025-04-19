open PulumiAws.PolicyDocument
open Reventless.Adapter

let snsResources = eventTopicResources =>
  eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.SNS.service,
    AWS.SNS_FIFO.service,
  ])
let dynamoDbStreamResources = eventTopicResources =>
  eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.DynamoDbStream.service,
  ])
let targetSnsResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.SNS.service,
    AWS.SNS_FIFO.service,
  ])
let targetSqsResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.SQS.service,
    AWS.SQS_FIFO.service,
  ])
let targetDynamoDbResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.DynamoDb.service,
    AWS.DynamoDbStream.service,
  ])

let toResources = (eventTopics: Reventless.EventTopic.allOutputs) =>
  eventTopics
  ->Js.Dict.values
  ->Array.flatMap(outputs => outputs.resources)
  ->Reventless.Adapter.resourcesToUnwrappedOutput

let connectSqsQueue2SnsTopics = (queue: PulumiAws.SQS.Queue.t, name, eventTopics, opts) => {
  let _ =
    (queue.arn, queue.id, eventTopics->toResources)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((queueArn, queueId, eventTopicResources)) => {
      Js.Console.log2(
        `EventCollectorChannel_Common: connectSqsQueue2SnsTopics ${queueId}: eventTopicResources:`,
        eventTopicResources,
      )
      let snsResources = eventTopicResources->snsResources

      let _queuePolicy = {
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

      let _snsTopicSubscriptions = snsResources->Array.map(snsResource => {
        Js.log3("EventCollectorChannel_Common: subscribeToSnsTopic:", name, snsResource)
        let subscription = Util_SQS.subscribeToSnsTopic(
          ~queue,
          ~targetName=name,
          ~sourceName=snsResource.name,
          ~topic=snsResource->Reventless.AdapterDeploytime.unwrappedToResource,
          ~opts,
        )
        subscription.id->Pulumi.Output.apply(id => Js.log3("created SNS subscription:", id, name))
      })

      // let _printWarningForEmptySnsTopic = if snsResources->Array.length == 0 {
      //   Js.log2("No SNS topics are present for EventCollectorChannel_Common", name)
      // }
    })
}

let connectLambda = (
  lambda: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t>,
  name: string,
  lambdaRole: PulumiAws.IAM.Role.t,
  queues: array<PulumiAws.SQS.Queue.t>,
  eventTopics: Reventless.EventTopic.allOutputs,
  resources: array<ReventlessSpec.Adapter.resource>,
  opts: Pulumi.CustomResourceOptions.t,
) => {
  let _ =
    (
      eventTopics->toResources,
      queues->Array.map(queue => queue.arn)->Pulumi.Output.all,
      resources->Reventless.Adapter.resourcesToUnwrappedOutput,
    )
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((eventTopicResources, queueArns, resources)) => {
      open PulumiAws.PolicyDocument
      open Reventless.Adapter

      Js.Console.log2(
        `EventCollectorChannel_Common: connectLambda ${name}: eventTopicResources:`,
        eventTopicResources,
      )
      Js.Console.log2(`EventCollectorChannel_Common: connectLambda ${name}: resources:`, resources)

      let dynamoDbStreamResources = eventTopicResources->dynamoDbStreamResources
      let targetSnsResources = resources->targetSnsResources
      let targetSqsResources = resources->targetSqsResources
      let targetDynamoDbResources = resources->targetDynamoDbResources

      let lambdaDynamoDbStreamPolicyDocuments =
        dynamoDbStreamResources->Array.length > 0
          ? Some(
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
          ? Some(
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
          : None

      let lambdaSqsSendPolicyDocument =
        targetSqsResources->Array.length > 0
          ? Some(
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
          : None

      let lambdaQueuePolicyDocument =
        queueArns->Array.length > 0
          ? Some(
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
                    resources: Resources(queueArns),
                  },
                ],
              ),
            )
          : None

      let _attachLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              lambdaQueuePolicyDocument,
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

  let subscriptionResources = queues->Array.map(queue =>
    lambda
    ->Pulumi.Output.apply(lambda =>
      queue
      ->PulumiAws.SQS.Queue.onEvent(~name, ~handler=lambda, ~opts)
      ->Util.SQS.Subscription.toResource
    )
    ->Reventless.Adapter.outputToResource
  )

  subscriptionResources
}
