open PulumiAws.PolicyDocument
open ReventlessCore.Adapter
open Adapter_Helpers

let log = ReventlessCore.Logger.fromEnv()

let toResources = (eventTopics: ReventlessCore.EventTopic.allOutputs) =>
  eventTopics
  ->Dict.valuesToArray
  ->Array.flatMap(outputs => outputs.resources)
  ->ReventlessCore.Adapter.resourcesToResolvedOutput

let createQueuePolicy = (queue: PulumiAws.SQS.Queue.t, name, _resources, opts) => {
  let _ =
    (queue.arn, queue.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queueArn, queueId)) => {
      // SQS queue ARN is `arn:aws:sqs:<region>:<accountId>:<name>` — segment
      // index 4 (0-based). Used to scope cross-plugin SNS sources to this
      // account (aws:SourceAccount) and to topic names following the
      // Reventless EventTopic naming convention (aws:SourceArn arnLike).
      let accountId = queueArn->String.split(":")->Array.get(4)->Option.getOr("")
      let queuePolicyDocument =
        PulumiAws.PolicyDocument.make(
          ~id=name ++ "QueuePolicy",
          ~statements=[
            // Single statement allows SendMessage from any SNS topic owned by
            // this AWS account whose name matches the Reventless EventTopic
            // naming convention. Replaces the previous per-topic arnEquals
            // list so cross-plugin SNS subscriptions created at runtime by the
            // admin's manageSubscriptions hook (Phase 3 Step 1) are accepted
            // without requiring a redeploy of the receiving plugin. Security
            // boundary: SourceAccount condition keeps third-party-account
            // topics out; ArnLike + SNS service principal further narrows
            // accepted senders to in-account EventTopic resources.
            {
              sid: "AllowReceiveSnsEvents",
              principal: Principals({
                service: PrincipalIds([AWS.SNS.principal]),
              }),
              effect: Allow,
              actions: Actions(["sqs:SendMessage"]),
              resources: Resource(queueArn),
              conditions: {
                stringEquals: [
                  ("aws:SourceAccount", ConditionValue(accountId)),
                ]->Dict.fromArray,
                arnLike: [
                  ("aws:SourceArn", ConditionValue(`arn:aws:sns:*:${accountId}:*EventTopic-*`)),
                ]->Dict.fromArray,
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

let subscribeQueue2SnsTopic = (queue, name, resources: array<ReventlessInfra.Adapter.resolvedResource>, opts) => {
  let _snsTopicSubscriptions = resources->Array.map(resource => {
    log.debug(~comp="EventCollector", `subscribeToSnsTopic: ${name} -> ${resource.name}`)
    let subscription = Util_SQS.subscribeToSnsTopic(
      ~queue,
      ~targetName=name,
      ~sourceName=resource.name,
      ~topic=resource->ReventlessCore.AdapterDeploytime.resolvedToResource,
      ~opts,
    )
    subscription.id->Pulumi.Output.apply(id => log.debug(~comp="EventCollector", `created SNS subscription: ${id} ${name}`))
  })
}

let connectSqsQueue2SnsTopics = (queue: PulumiAws.SQS.Queue.t, name, eventTopics, opts) => {
  let _ =
    (eventTopics->toResources, queue.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventTopicResources, queueId)) => {
      log.debug(
        ~comp="EventCollector",
        `connectSqsQueue2SnsTopics ${queueId}: ${eventTopicResources->Array.length->Int.toString} topic resource(s)`,
      )
      let snsResources = eventTopicResources->snsResources
      queue->createQueuePolicy(name, snsResources, opts)
      queue->subscribeQueue2SnsTopic(name, snsResources, opts)
    })
}

let connectLambda = (
  lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  name: string,
  lambdaRole: PulumiAws.IAM.Role.t,
  queues: array<PulumiAws.SQS.Queue.t>,
  eventTopics: ReventlessCore.EventTopic.allOutputs,
  resources: array<ReventlessInfra.Adapter.resource>,
  opts: Pulumi.CustomResourceOptions.t,
) => {
  let _ =
    (
      eventTopics->toResources,
      queues->Array.map(queue => queue.arn)->Pulumi.Output.all,
      resources->ReventlessCore.Adapter.resourcesToResolvedOutput,
    )
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((eventTopicResources, queueArns, resources)) => {
      log.debug(
        ~comp="EventCollector",
        `connectLambda ${name}: ${eventTopicResources->Array.length->Int.toString} topic resource(s), ${resources->Array.length->Int.toString} resource(s)`,
      )

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
            ~source=dynamoDbStreamResource->ReventlessCore.AdapterDeploytime.resolvedToResource,
            ~opts,
          )
        )
    })

  let subscriptionResources = queues->Array.mapWithIndex((queue, idx) => {
    let esmName = queues->Array.length > 1 ? `${name}Sqs${Int.toString(idx)}` : name
    Util_EventSourceMapping.subscribeSqs(~lambda, ~name=esmName, ~queue, ~opts)
  })

  subscriptionResources
}
