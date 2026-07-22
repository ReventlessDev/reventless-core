open PulumiAws.PolicyDocument
open Adapter_Helpers

let createQueuePolicy = (
  queue: PulumiAws.SQS.Queue.t,
  name,
  lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  opts,
) => {
  // The document is a *value* derived from resolved ARNs, so it is built in an
  // apply. The QueuePolicy itself stays outside: passing `queue.id` as an Output
  // is what registers the policy -> queue dependency, without which Pulumi has
  // no ordering constraint and can delete the queue first on a replacement,
  // leaving the policy's delete polling a queue that no longer exists.
  let queuePolicyDocument =
    (queue.arn, lambda->Pulumi.Output.flatMap(lambda => lambda.arn))
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queueArn, lambdaArn)) =>
      PulumiAws.PolicyDocument.make(
        ~id=name ++ "QueuePolicy",
        ~statements=[
          {
            sid: "AllowLambdaToAccessQueue",
            effect: Allow,
            principal: Principals({
              service: PrincipalId("lambda.amazonaws.com"),
            }),
            actions: Actions(["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]),
            resources: Resource(queueArn),
            conditions: {
              arnEquals: [("AWS:SourceArn", ConditionValue(lambdaArn))]->Dict.fromArray,
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
      )->toJsonString
    )
  let _queuePolicy = PulumiAws.SQS.QueuePolicy.make(
    ~name,
    ~args={
      queueUrl: queue.id->Pulumi.Output.asInput,
      policy: queuePolicyDocument->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )
}

let createLambdaPolicy = (
  lambdaRole: PulumiAws.IAM.Role.t,
  name: string,
  queue: PulumiAws.SQS.Queue.t,
  resources: array<ReventlessInfra.Adapter.resource>,
  opts: Pulumi.CustomResourceOptions.t,
) => {
  let _ =
    (queue.arn, resources->ReventlessCore.Adapter.resourcesToResolvedOutput)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((queueArn, resources)) => {
      let allowSQSSendLambda =
        resources->sqsResources->Array.length > 0
          ? Some(
              PulumiAws.PolicyDocument.make(
                ~id=name ++ "RemoteSQSLambdaPolicy",
                ~statements=[
                  {
                    sid: "AllowLambdaSendMessageSQS",
                    effect: Allow,
                    actions: Action("sqs:SendMessage"),
                    resources: Resources(
                      resources->sqsResources->Array.map(sqsResource => sqsResource.urn),
                    ),
                  },
                ],
              ),
            )
          : None

      let allowLambdaReadWriteDynamoDb =
        resources->dynamoDbResources->Array.length > 0
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
                      // Phase 7 cross-partition fences emit read-only
                      // `ConditionCheck` entries inside `TransactWriteItems`
                      // when a write doesn't touch the cross-partition tag's
                      // partition itself; this needs its own IAM action.
                      "dynamodb:ConditionCheckItem",
                    ]),
                    resources: Resources(
                      resources
                      ->dynamoDbResources
                      ->Array.flatMap(dynamoDbResource => [
                        dynamoDbResource.urn,
                        dynamoDbResource.urn ++ "/index/*",
                      ]),
                    ),
                  },
                ],
              ),
            )
          : None

      let allowLambdaWriteCloudWatchEvents = PulumiAws.PolicyDocument.make(
        ~id=name ++ "LambdaCloudWatchEventsPolicy",
        ~statements=[
          {
            sid: "AllowLambdaWriteCloudWatchEvents",
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

      let allowLambdaReceiveSQS = PulumiAws.PolicyDocument.make(
        ~id=name ++ "SQSLambdaPolicy",
        ~statements=[
          {
            sid: "AllowLambdaReceiveSQS",
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
              stringEquals: Dict.fromArray([
                ("iam:PassedToService", ConditionValue("events.amazonaws.com")),
              ]),
            },
          },
        ],
      )

      let _lambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name,
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "LambdaPolicy",
            [
              Some(PulumiAws.Lambda.defaultLoggingPolicyDocument),
              Some(allowLambdaReceiveSQS),
              Some(allowLambdaWriteCloudWatchEvents),
              Some(allowLambdaPassRoleToEvents),
              allowLambdaReadWriteDynamoDb,
              allowSQSSendLambda,
            ]->Array.keepSome,
          )->Pulumi.Output.asInput,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )
    })
}

let subscribeLambda2SqsTopic = (~batchSize=?, lambda, name, queue, opts) =>
  Util_EventSourceMapping.subscribeSqs(~lambda, ~name, ~queue, ~batchSize?, ~opts)
