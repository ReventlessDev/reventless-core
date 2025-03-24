type runtimeParts = Util.Lambda.runtimeParts

let make: Reventless.Heartbeat_Adapter.runnerMaker<runtimeParts> = (
  ~name,
  ~timeout,
  ~runtime,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let cloudwatchEventRule = {
    open PulumiAws.Cloudwatch
    EventRule.make(
      ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ name),
      ~args={
        description: "Send a heartbeat to the Core Plugin ExtensionPoint"->Pulumi.Input.make,
        scheduleExpression: EventRule.ScheduleExpression.every(timeout->Minutes),
      },
      ~opts,
    )
  }

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  let _attachPoliciesAndSetEventTarget =
    (
      lambda->Pulumi.Output.flatMap(lambda => lambda.arn),
      lambda->Pulumi.Output.flatMap(lambda => lambda.name),
      lambdaRole.id,
    )
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((lambdaArn, lambdaName, heartbeatRoleId)) => {
      open PulumiAws.PolicyDocument

      let _addHeartbeatLambdaPermission = PulumiAws.Lambda.Permission.make(
        ~name=name ++ "Permission",
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaName->Pulumi.Input.make,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts,
      )

      let heartbeatLambdaSendMessagePolicyDocument = {
        open PulumiAws.PolicyDocument
        PulumiAws.PolicyDocument.make(
          ~statements=[
            {
              sid: "AllowLambdaToSendSQS",
              effect: Allow,
              actions: Action("sqs:SendMessage"),
              resources: Resource(lambdaArn),
            },
          ],
        )
      }

      let _attachHeartbeatLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "RolePolicy",
        ~args={
          policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
            name ++ "Policy",
            [
              PulumiAws.Lambda.defaultLoggingPolicyDocument,
              heartbeatLambdaSendMessagePolicyDocument,
            ],
          )->Pulumi.Output.asInput,
          role: heartbeatRoleId->Pulumi.Input.make,
        },
      )

      let _cloudwatchEventTarget = {
        open PulumiAws.Cloudwatch
        EventTarget.make(
          ~name,
          ~args={
            rule: EventTarget.Rule.ofEventRule(cloudwatchEventRule),
            arn: lambdaArn->Pulumi.Input.make,
          },
          ~opts,
        )
      }
    })

  {
    resources: [
      lambda
      ->Pulumi.Output.apply(lambda => lambda->Util_Lambda.toResource)
      ->Reventless.Adapter.outputToResource,
      cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource,
    ],
  }
}
