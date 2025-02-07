let componentType = ComponentType.Heartbeat

type outputs = {name: string}

type t
type component = Component.t<t, outputs>

type constructed
type construct = (component, string) => constructed

@module("./Component") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component = "default"

@send
external registerOutputs: (component, outputs) => constructed = "registerOutputs"
@send
external setOutputs: (component, outputs) => unit = "setOutputs"
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs)
  self->registerOutputs(outputs)
}

let construct = (~id, ~timeout, ~publishToCorePluginExtensionPoint, self, name) => {
  let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

  // Heartbeat + HealthCheck
  // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

  let _ =
    publishToCorePluginExtensionPoint->Pulumi.Output.apply(publishToCorePluginExtensionPoint => {
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

      let _cloudwatchEventTarget = {
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

      let _heartbeatLambdaPermission = {
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
    })

  self->setOutputs({name: name})
}

let make = (~id, ~name, ~timeout=10, ~publishToCorePluginExtensionPoint, ~opts=?) =>
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name,
    ~construct=construct(~id, ~timeout, ~publishToCorePluginExtensionPoint, ...),
    ~opts,
  )
