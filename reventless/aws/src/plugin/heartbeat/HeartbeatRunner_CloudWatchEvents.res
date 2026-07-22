type runtimeParts = Util.Lambda.runtimeParts

let make: ReventlessCore.Heartbeat_Adapter.runnerMaker<runtimeParts> = (
  ~name,
  ~remoteChannel,
  ~timeout,
  ~runtime,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let cloudwatchEventRule = {
    open PulumiAws.Cloudwatch
    EventRule.make(
      ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ name),
      ~args={
        description: "Send a heartbeat to the Core Plugin ExtensionPoint"->Pulumi.Input.make,
        scheduleExpression: EventRule.ScheduleExpression.every(timeout->Minutes),
        tags: AWS.Tags.make(
          ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ name),
          ~kind=ReventlessCore.Heartbeat.componentType,
          ~role=Scheduler,
          ~component=name,
        ),
      },
      ~opts,
    )
  }

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole
  let coreSqsQueue = remoteChannel.resources->Util_SQS.findResolvedResource

  // Grant sqs:SendMessage on the Core Plugin ExtensionPoint command topic at
  // TOP LEVEL. Previously this RolePolicy was created inside the
  // `Pulumi.Output.apply` below — and a resource created inside an apply
  // callback does not reliably register with the engine, which intermittently
  // left the heartbeat Lambda without this grant (IAM AccessDenied:
  // `sqs:sendmessage on CorePluginExtPointCmdTopic`). `coreSqsQueue.urn` is an
  // already-resolved ARN string from the remote channel and `lambdaRole.id` an
  // Output, so neither needs an apply. Mirrors the EC `pta` grant fix — see
  // docs/analysis/ec-publish-to-aggregates-grant-broken.md.
  let _attachHeartbeatLambdaPolicy = {
    open PulumiAws.PolicyDocument
    let heartbeatLambdaSendMessagePolicyDocument = PulumiAws.PolicyDocument.make(
      ~statements=[
        {
          sid: "AllowLambdaToSendSQS",
          effect: Allow,
          actions: Action("sqs:SendMessage"),
          resources: Resource(coreSqsQueue.urn),
        },
      ],
    )
    PulumiAws.IAM.RolePolicy.make(
      ~name=name ++ "RolePolicy",
      ~args={
        policy: PulumiAws.PolicyDocument.mergePolicyDocuments(
          name ++ "Policy",
          [
            PulumiAws.Lambda.defaultLoggingPolicyDocument,
            heartbeatLambdaSendMessagePolicyDocument,
          ],
        )->Pulumi.Output.asInput,
        role: lambdaRole.id->Pulumi.Output.asInput,
      },
    )
  }

  // The Lambda permission and CloudWatch event target genuinely need the
  // Lambda's resolved arn/name, so they stay inside an apply.
  let _permissionAndEventTarget =
    (lambda->Pulumi.Output.flatMap(lambda => lambda.arn), lambda->Pulumi.Output.flatMap(lambda => lambda.name))
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, lambdaName)) => {
      let _addHeartbeatLambdaPermission = PulumiAws.Lambda.Permission.make(
        ~name,
        ~args={
          action: "lambda:InvokeFunction",
          function: lambdaName->Pulumi.Input.make,
          principal: AWS.CloudwatchEventRule.principal,
        },
        ~opts,
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
      ->ReventlessCore.Adapter.outputToResource,
      cloudwatchEventRule->Util_Cloudwatch.EventRule.toResource,
    ],
  }
}
