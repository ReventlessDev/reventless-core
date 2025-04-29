open PulumiAws.PolicyDocument
open Adapter_Helpers

let createQueuePolicy = (
  queue: PulumiAws.SQS.Queue.t,
  name,
  lambda: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t>,
  opts,
) => {
  let _ =
    (queue.arn, queue.id, lambda->Pulumi.Output.flatMap(lambda => lambda.arn))
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((queueArn, queueId, lambdaArn)) => {
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
        )
        ->toJsonString
        ->Pulumi.Input.make
      let _queuePolicy = PulumiAws.SQS.QueuePolicy.make(
        ~name,
        ~args={queueUrl: queueId->Pulumi.Input.make, policy: queuePolicyDocument},
        ~opts=Some(opts),
      )
    })
}

let createLambdaPolicy = (
  lambdaRole: PulumiAws.IAM.Role.t,
  name: string,
  queue: PulumiAws.SQS.Queue.t,
  resources: array<ReventlessSpec.Adapter.resource>,
  opts: Pulumi.CustomResourceOptions.t,
) => {
  let _ =
    (queue.arn, resources->Reventless.Adapter.resourcesToUnwrappedOutput)
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
                    ]),
                    resources: Resources(
                      resources
                      ->dynamoDbResources
                      ->Array.map(dynamoDbResource => dynamoDbResource.urn),
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
              stringEquals: Js.Dict.fromArray([
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

let subscribeLambda2SqsTopic = (lambda, name, queue, opts) =>
  lambda
  ->Pulumi.Output.apply(lambda => {
    queue
    ->PulumiAws.SQS.Queue.onEvent(~name, ~handler=lambda, ~opts)
    ->Util.SQS.Subscription.toResource
  })
  ->Reventless.Adapter.outputToResource
