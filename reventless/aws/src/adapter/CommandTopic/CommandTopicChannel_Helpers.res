open PulumiAws.PolicyDocument
open Adapter_Helpers

// EventBridge Scheduler delivers to the queue as the scheduler role, which holds
// sqs:SendMessage itself, so the queue's own policy admits only its Lambda.
let createQueuePolicyDocument = (~name, ~queueArn: string, ~lambdaArn: string) =>
  PulumiAws.PolicyDocument.make(
    ~id=name ++ "QueuePolicy",
    ~statements=[
      {
        sid: "AllowLambdaToAccessQueue",
        effect: Allow,
        principal: Principals({
          service: PrincipalId(AWS.Lambda.principal),
        }),
        actions: Actions(["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]),
        resources: Resource(queueArn),
        conditions: {
          arnEquals: [("AWS:SourceArn", ConditionValue(lambdaArn))]->Dict.fromArray,
        },
      },
    ],
  )->toJsonString

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
      createQueuePolicyDocument(~name, ~queueArn, ~lambdaArn)
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
                      // Cross-partition fences emit read-only `ConditionCheck`
                      // entries inside `TransactWriteItems` when a write
                      // doesn't touch the cross-partition tag's partition
                      // itself; this needs its own IAM action.
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

      // The scheduler role is not known here, so the grant names every
      // scheduler group in the account rather than this platform's one.
      let allowLambdaManageSchedules = PulumiAws.PolicyDocument.make(
        ~id=name ++ "LambdaSchedulerPolicy",
        ~statements=[
          {
            sid: "AllowLambdaManageSchedules",
            effect: Allow,
            actions: Actions(ScheduledPublisher_EventBridgeScheduler_Runtime.manageActions),
            resources: Resource(
              queueArn
              ->accountIdOfQueueArn
              ->ScheduledPublisher_EventBridgeScheduler_Runtime.schedulesOfAccount,
            ),
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

      let allowLambdaPassRoleToScheduler = PulumiAws.PolicyDocument.make(
        ~id=name ++ "LambdaPassRoleToScheduler",
        ~statements=[
          {
            sid: "AllowLambdaPassRoleToScheduler",
            effect: Allow,
            actions: Action("iam:PassRole"),
            resources: Resource("*"),
            conditions: {
              stringEquals: Dict.fromArray([
                ("iam:PassedToService", ConditionValue(AWS.EventBridgeScheduler.principal)),
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
              Some(allowLambdaManageSchedules),
              Some(allowLambdaPassRoleToScheduler),
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
  Util_EventSourceMapping.subscribeSqs(
    ~lambda,
    ~name,
    ~queue,
    ~batchSize?,
    ~tags=AWS.Tags.make(
      ~name,
      ~kind=ReventlessCore.CommandTopic.componentType,
      ~role=EventSourceMapping,
    ),
    ~opts,
  )
