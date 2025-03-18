let make: Reventless.Heartbeat_Adapter.runnerMaker = (~name, ~timeout, ~runtime, ~opts) => {
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

  let heartbeatLambdaRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Role",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
  )

  let lambdaResource = runtime.resources->Util.Lambda.findResource

  let _attachHeartbeatLambdaRolePolicy =
    (lambdaResource.urn, cloudwatchEventRule.arn)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaUrn, ruleArn)) => {
      open PulumiAws.PolicyDocument

      let _addHeartbeatLambdaPermission = PulumiAws.Lambda.Permission.make(
        ~name="AllowLambdaInvokeFromCloudWatchEvents",
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaResource.urn->Pulumi.Output.asInput,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts,
      )

      PulumiAws.IAM.RolePolicy.make(
        ~name=name ++ "RolePolicy",
        ~args={
          policy: PulumiAws.Lambda.defaultLoggingPolicyDocument->toJsonString->Pulumi.Input.make,
          role: heartbeatLambdaRole.id->Pulumi.Output.asInput,
        },
      )
    })

  let _cloudwatchEventTarget = {
    open PulumiAws.Cloudwatch
    EventTarget.make(
      ~name,
      ~args={
        rule: EventTarget.Rule.ofEventRule(cloudwatchEventRule),
        arn: lambdaResource.urn->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  {
    resources: [lambdaResource, cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource],
  }
}
