let make: Reventless.Heartbeat_Adapter.runnerMaker = (~name, ~timeout, ~heartbeat, ~opts) => {
  let heartBeatCallback: PulumiAws.Lambda.eventHandler<unit, unit> = (_, _) => heartbeat()

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

  let heartbeatLambda = {
    open PulumiAws.Lambda
    CallbackFunction.make(
      ~name,
      ~args=CallbackFunction.Args.make(
        ~callback=heartBeatCallback,
        /* TODO: add deadLetterConfig after extraction to ReventlessAws:
               ~deadLetterConfig=
                 CallbackFunction.Args.DeadLetterConfig.make(
                   ~targetArn=PulumiAws.Util_DeadLetterQueue.queue##arn,
                 ),
 */
      ),
      ~opts,
    )
  }

  let _cloudwatchEventTarget = {
    open PulumiAws.Cloudwatch
    EventTarget.make(
      ~name,
      ~args={
        rule: EventTarget.Rule.ofEventRule(cloudwatchEventRule),
        arn: heartbeatLambda.arn->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  let _heartbeatLambdaPermission = {
    open PulumiAws.Lambda
    Permission.make(
      ~name,
      ~args={
        function: heartbeatLambda.arn->Pulumi.Output.asInput,
        action: "lambda:InvokeFunction",
        principal: "events.amazonaws.com",
        sourceArn: cloudwatchEventRule.arn->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  {
    resources: [
      heartbeatLambda->Util_Lambda.toResource,
      cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource,
    ],
  }
}
