let componentType = ComponentType.Heartbeat;

type outputs = {. "name": string};

type heartbeat; // TODO: rename to t - after refactoring

type constructed;
type construct = (Component.t(heartbeat, outputs), string) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  Component.t(heartbeat, outputs) =
  "default";

[@bs.obj] external makeOutputs: (~name: string) => outputs = "";

type outputsToRegister;
[@bs.obj]
external makeOutputsToRegister:
  (
    ~name: string,
    ~cloudwatchEventRule: PulumiAws.Cloudwatch_EventRule.t,
    ~cloudwatchEventTarget: PulumiAws.Cloudwatch_EventTarget.t,
    ~heartbeatLambdaPermission: PulumiAws.Lambda.Permission.t
  ) =>
  outputsToRegister =
  "";

[@bs.send]
external registerOutputs:
  (Component.t(heartbeat, outputs), outputsToRegister) => constructed =
  "registerOutputs";
[@bs.send]
external setOutputs: (Component.t(heartbeat, outputs), outputs) => unit =
  "setOutputs";

let construct = (~id, ~timeout, ~commandTopicId, self, name) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Component.toPulumiResource,
      (),
    );

  // Heartbeat + HealthCheck
  // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

  let publishHeartbeatCommand = () => {
    let msgId = Message.uuid();
    {
      Message.id: id->Id.String.makeFromString,
      meta: {
        service: PluginExtensionPointSpec.name,
        time: Message.nowAsISOString(),
        ip: "",
        user: "Heartbeat",
        msgId,
        correlationId: msgId,
      },
      command: PluginExtensionPointSpec.Heartbeat(timeout),
    }
    ->Message.command'_encode(
        Id.String.t_encode,
        PluginExtensionPointSpec.command_encode,
        _,
      )
    ->Js.Json.stringify
    ->Message.log("Sending Heartbeat:", _)
    ->AwsSdk.SQS.sendMessage(
        ~queueId=commandTopicId->Pulumi.Output.get,
        ~messageBody=_,
        (),
      )
    ->Js.Promise.catch(
        err =>
          err
          ->Js.log2("Extension: Error on publish command:", _)
          ->Js.Promise.resolve,
        _,
      );
  };

  let childName = name->ComponentType.name(componentType);

  let heartBeatCallback: PulumiAws.Lambda.eventHandler(unit, unit) =
    (_, _) => publishHeartbeatCommand();

  let cloudwatchEventRule =
    PulumiAws.Cloudwatch.(
      EventRule.make(
        ~name=Pulumi.Pulumi.getStackName() ++ "-" ++ childName,
        ~args=
          EventRule.Args.make(
            ~description=
              "Send a heartbeat to the Core Plugin ExtensionPoint"
              ->Pulumi.Input.wrap,
            ~scheduleExpression=
              EventRule.Args.ScheduleExpression.every(timeout->Minutes),
            (),
          ),
        ~opts,
        (),
      )
    );

  let heartbeatLambda =
    PulumiAws.Lambda.(
      CallbackFunction.make(
        ~name=childName,
        ~args=
          CallbackFunction.Args.make(
            ~callback=heartBeatCallback,
            ~policies=[|
              PulumiAws.SQS.QueuePolicy.amazonSQSFullAccess,
              PulumiAws.Lambda.Policy.awsLambdaFullAccess,
            |],
            (),
            /* TODO: add deadLetterConfig after extraction to ReventlessAws:
               ~deadLetterConfig=
                 CallbackFunction.Args.DeadLetterConfig.make(
                   ~targetArn=PulumiAws.Util_DeadLetterQueue.queue##arn,
                 ),
                 */
          ),
        ~opts,
        (),
      )
    );

  let cloudwatchEventTarget =
    PulumiAws.Cloudwatch.(
      EventTarget.make(
        ~name=childName,
        ~args=
          EventTarget.Args.make(
            ~rule=EventTarget.Args.Rule.ofEventRule(cloudwatchEventRule),
            ~arn=heartbeatLambda##arn->Pulumi.Output.asInput,
            (),
          ),
        ~opts,
        (),
      )
    );

  let heartbeatLambdaPermission =
    PulumiAws.Lambda.(
      Permission.make(
        ~name=childName,
        ~args=
          Permission.Args.make(
            ~_function=heartbeatLambda##arn->Pulumi.Output.asInput,
            ~action="lambda:InvokeFunction",
            ~principal="events.amazonaws.com",
            ~sourceArn=cloudwatchEventRule##arn->Pulumi.Output.asInput,
            (),
          ),
        ~opts,
        (),
      )
    );

  makeOutputs(~name)->setOutputs(self, _);

  makeOutputsToRegister(~name, ~cloudwatchEventRule, ~cloudwatchEventTarget, ~heartbeatLambdaPermission)
  ->registerOutputs(self, _);
};

let make = (~id, ~name, ~timeout=10, ~commandTopicId, ~opts=?, _) =>
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name,
    ~construct=construct(~id, ~timeout, ~commandTopicId),
    ~opts,
  );
