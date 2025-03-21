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

  let heartbeatLambdaRole = PulumiAws.IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Role",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts,
  )

  let lambdaResource = runtime.resources->Util.Lambda.findResource

  let _attachHeartbeatLambdaRolePolicy =
    (lambdaResource.urn, cloudwatchEventRule.arn)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaUrn, _ruleArn)) => {
      open PulumiAws.PolicyDocument

      let _addHeartbeatLambdaPermission = PulumiAws.Lambda.Permission.make(
        ~name=name++"Permission",
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaUrn->Pulumi.Input.make,
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
