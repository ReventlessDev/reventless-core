open PulumiAws.PolicyDocument
open Reventless.Adapter
open Adapter_Helpers

let toResources = (eventTopics: Reventless.EventTopic.allOutputs) =>
  eventTopics
  ->Dict.valuesToArray
  ->Array.flatMap(outputs => outputs.resources)
  ->Reventless.Adapter.resourcesToUnwrappedOutput

let createQueuePolicy = (queue: PulumiAws.SQS.Queue.t, name, resources, opts) => {
  let _ =
    (queue.arn, queue.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queueArn, queueId)) => {
      let queuePolicyDocument =
        PulumiAws.PolicyDocument.make(
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
                arnEquals: [("aws:SourceArn", ConditionValues(resources->urns))]->Dict.fromArray,
              },
            },
          ],
        )
        ->toJsonString
        ->Pulumi.Input.make
      let _queuePolicy = {
        PulumiAws.SQS.QueuePolicy.make(
          ~name,
          ~args={
            queueUrl: queueId->Pulumi.Input.make,
            policy: queuePolicyDocument,
          },
          ~opts=Some(opts),
        )
      }
    })
}

let subscribeQueue2SnsTopic = (queue, name, resources, opts) => {
  let _snsTopicSubscriptions = resources->Array.map(resource => {
    Console.log3("EventCollectorChannel_Helpers.subscribeToSnsTopic:", name, resource)
    let subscription = Util_SQS.subscribeToSnsTopic(
      ~queue,
      ~targetName=name,
      ~sourceName=resource.name,
      ~topic=resource->Reventless.AdapterDeploytime.unwrappedToResource,
      ~opts,
    )
    subscription.id->Pulumi.Output.apply(id => Console.log3("created SNS subscription:", id, name))
  })
}

let connectSqsQueue2SnsTopics = (queue: PulumiAws.SQS.Queue.t, name, eventTopics, opts) => {
  let _ =
    (eventTopics->toResources, queue.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventTopicResources, queueId)) => {
      Console.log2(
        `EventCollectorChannel_Helpers.connectSqsQueue2SnsTopics ${queueId}: eventTopicResources:`,
        eventTopicResources,
      )
      let snsResources = eventTopicResources->snsResources
      queue->createQueuePolicy(name, snsResources, opts)
      queue->subscribeQueue2SnsTopic(name, snsResources, opts)

      // if snsResources->Array.length == 0 {
      //   Console.log2(`No SNS topics are present for ${name}`)
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
      Console.log2(
        `EventCollectorChannel_Helpers.connectLambda ${name}: eventTopicResources:`,
        eventTopicResources,
      )
      Console.log2(`EventCollectorChannel_Helpers.connectLambda ${name}: resources:`, resources)

      let dynamoDbStreamResources = eventTopicResources->dynamoDbStreamResources
      let targetSnsResources = resources->snsResources
      let targetSqsResources = resources->sqsResources
      let targetDynamoDbResources = resources->dynamoDbResources

      let allowLambdaReadDynamoDbStream =
        dynamoDbStreamResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaDynamoDbStreamPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaReadDynamoDbStream",
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

      let allowLambdaReadWriteDynamoDb =
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

      let allowLambdaPublishSNS =
        targetSnsResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "PublishSNS",
                ~statements=[
                  {
                    sid: "AllowLambdaPublishSNS",
                    effect: Allow,
                    actions: Action("sns:Publish"),
                    resources: Resources(targetSnsResources->urns),
                  },
                ],
              ),
            )
          : None

      let allowLambdaSendSQS =
        targetSqsResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "SendSQS",
                ~statements=[
                  {
                    sid: "AllowLambdaSendSQS",
                    effect: Allow,
                    actions: Action("sqs:SendMessage"),
                    resources: Resources(targetSqsResources->urns),
                  },
                ],
              ),
            )
          : None

      let allowLambdaReceiveSQS =
        queueArns->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "LambdaSQSPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaReceiveSQS",
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

      let _lambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              allowLambdaReceiveSQS,
              allowLambdaReadDynamoDbStream,
              allowLambdaReadWriteDynamoDb,
              allowLambdaPublishSNS,
              allowLambdaSendSQS,
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
