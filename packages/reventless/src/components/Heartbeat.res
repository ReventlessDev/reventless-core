let componentType = ComponentType.Heartbeat

type outputs = {name: string}

type heartbeat // TODO: rename to t - after refactoring

type constructed
type construct = (ReventlessSpec.Component.t<heartbeat, outputs>, string) => constructed

@module("./Component") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => ReventlessSpec.Component.t<heartbeat, outputs> = "default"

type outputsToRegister
@obj
external makeOutputsToRegister: (
  ~name: string,
  ~cloudwatchEventRule: PulumiAws.Cloudwatch_EventRule.t,
  ~cloudwatchEventTarget: PulumiAws.Cloudwatch_EventTarget.t,
  ~heartbeatLambdaPermission: PulumiAws.Lambda.Permission.t,
) => outputsToRegister = ""

@send
external registerOutputs: (
  ReventlessSpec.Component.t<heartbeat, outputs>,
  outputsToRegister,
) => constructed = "registerOutputs"
@send
external setOutputs: (ReventlessSpec.Component.t<heartbeat, outputs>, outputs) => unit =
  "setOutputs"

let construct = (~id, ~timeout, ~publishToCorePluginExtensionPoint, self, name) => {
  let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

  // Heartbeat + HealthCheck
  // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

  let publishHeartbeatCommand = () => {
    let msgId = Message.uuid()
    publishToCorePluginExtensionPoint([
      {
        Message.id,
        meta: {
          service: ReventlessSpec.PluginExtensionPointSpec.name,
          time: Message.nowAsISOString(),
          ip: "",
          user: "Heartbeat",
          msgId,
          correlationId: msgId,
        },
        commandJson: {
          open ReventlessSpec.PluginExtensionPointSpec
          Heartbeat(timeout)->command_encode
        },
        delay: None,
      },
    ])
  }

  let childName = name->ComponentType.name(componentType)

  let heartBeatCallback: PulumiAws.Lambda.eventHandler<unit, unit> = (_, _) =>
    publishHeartbeatCommand()

  let cloudwatchEventRule = {
    open PulumiAws.Cloudwatch
    EventRule.make(
      ~name=Pulumi.Pulumi.getStackName() ++ ("-" ++ childName),
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
      ~name=childName,
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

  let cloudwatchEventTarget = {
    open PulumiAws.Cloudwatch
    EventTarget.make(
      ~name=childName,
      ~args={
        rule: EventTarget.Rule.ofEventRule(cloudwatchEventRule),
        arn: heartbeatLambda.arn->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  let heartbeatLambdaPermission = {
    open PulumiAws.Lambda
    Permission.make(
      ~name=childName,
      ~args={
        function: heartbeatLambda.arn->Pulumi.Output.asInput,
        action: "lambda:InvokeFunction",
        principal: "events.amazonaws.com",
        sourceArn: cloudwatchEventRule.arn->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  self->setOutputs({name: name})

  makeOutputsToRegister(
    ~name,
    ~cloudwatchEventRule,
    ~cloudwatchEventTarget,
    ~heartbeatLambdaPermission,
  )->registerOutputs(self, _)
}

let make = (~id, ~name, ~timeout=10, ~publishToCorePluginExtensionPoint, ~opts=?) =>
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name,
    ~construct=construct(~id, ~timeout, ~publishToCorePluginExtensionPoint, ...),
    ~opts,
  )
