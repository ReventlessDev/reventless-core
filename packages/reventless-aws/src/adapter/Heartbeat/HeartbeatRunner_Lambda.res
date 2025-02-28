let make: Reventless.Heartbeat_Adapter.runnerMaker = (~name, ~timeout, ~runtime, ~opts) => {
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

  let lambdaResource = runtime.resources->Util.Lambda.findResource

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

  let _heartbeatLambdaPermission = {
    open PulumiAws.Lambda
    Permission.make(
      ~name,
      ~args={
        function: lambdaResource.urn->Pulumi.Output.asInput,
        action: "lambda:InvokeFunction",
        principal: "events.amazonaws.com",
        sourceArn: cloudwatchEventRule.arn->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  {
    resources: [lambdaResource, cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource],
  }
}
