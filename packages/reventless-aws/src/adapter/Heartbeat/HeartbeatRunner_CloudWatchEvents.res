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

  let heartbeatLambda = runtime.parts.lambda
  let heartbeatLambdaRole = runtime.parts.lambdaRole

  let _attachPoliciesAndSetEventTarget =
    (heartbeatLambda.arn, heartbeatLambdaRole.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((heartbeatLambdaArn, heartbeatRoleId)) => {
      open PulumiAws.PolicyDocument

      let _addHeartbeatLambdaPermission = PulumiAws.Lambda.Permission.make(
        ~name=name ++ "Permission",
        ~args={
          action: "lambda:InvokeFunction",
          function: heartbeatLambdaArn->Pulumi.Input.make,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts,
      )

      let _attachHeartbeatLambdaPolicy = PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "RolePolicy",
        ~args={
          policy: PulumiAws.Lambda.defaultLoggingPolicyDocument->toJsonString->Pulumi.Input.make,
          role: heartbeatRoleId->Pulumi.Input.make,
        },
      )

      let _cloudwatchEventTarget = {
        open PulumiAws.Cloudwatch
        EventTarget.make(
          ~name,
          ~args={
            rule: EventTarget.Rule.ofEventRule(cloudwatchEventRule),
            arn: heartbeatLambdaArn->Pulumi.Input.make,
          },
          ~opts,
        )
      }
    })

  {
    resources: [
      heartbeatLambda->Util_Lambda.toResource,
      cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource,
    ],
  }
}
