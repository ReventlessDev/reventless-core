let componentType = ComponentType.Heartbeat;

type outputs = {
  .
  "name": string,
  "cloudwatchEventRule": PulumiAws.Cloudwatch_EventRule.t,
  "cloudwatchEventTarget": PulumiAws.Cloudwatch_EventTarget.t,
};
type t = outputs;

type constructed;
type construct = (t, string) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  t =
  "default";

[@bs.obj]
external makeOutputs:
  (
    ~name: string,
    ~cloudwatchEventRule: PulumiAws.Cloudwatch_EventRule.t,
    ~cloudwatchEventTarget: PulumiAws.Cloudwatch_EventTarget.t
  ) =>
  outputs =
  "";

[@bs.send]
external registerOutputs: (t, outputs) => constructed = "registerOutputs";
[@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

let construct = (self, name, ~id, ~timeout, ~commandTopicId) => {
  let opts =
    Pulumi.ComponentResource.Options.make(
      ~parent=self->Pulumi.Resource.makeFromJs,
      (),
    );

  // Heartbeat + HealthCheck
  // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

  let publishHeartbeatCommand = () => {
    let msgId = Message.uuid();
    {
      Message.id,
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
    ->AwsSdk.SQS.sendMessage(~queueId=commandTopicId, ~messageBody=_, ())
    ->Js.Promise.catch(
        err =>
          err
          ->Js.log2("Extension: Error on publish command:", _)
          ->Js.Promise.resolve,
        _,
      );
  };

  let heartbeatName = name ++ "Heartbeat";

  let heartBeatCallback: PulumiAws.Lambda.eventHandler(unit, unit) =
    (_, _) => publishHeartbeatCommand();

  let cloudwatchEventRule =
    PulumiAws.Cloudwatch.(
      EventRule.make(
        ~name=heartbeatName,
        ~args=
          EventRule.Args.make(
            ~description=
              "Send a heartbeat to the Core Plugin ExtensionPoint"
              ->Pulumi.Input.wrap,
            ~scheduleExpression=
              EventRule.Args.ScheduleExpression.every(timeout->Minutes),
            (),
          ),
        //~opts=opts->Obj.magic, // TODO: is ComponentResource.Options still relevant in today's Pulumi version
        (),
      )
    );

  let heartbeatLambda =
    PulumiAws.Lambda.(
      CallbackFunction.make(
        ~name=heartbeatName,
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
        //~opts=opts->Obj.magic, // TODO: is ComponentResource.Options still relevant in today's Pulumi version
        (),
      )
    );

  let cloudwatchEventTarget =
    PulumiAws.Cloudwatch.(
      EventTarget.make(
        ~name=heartbeatName,
        ~args=
          EventTarget.Args.make(
            ~rule=EventTarget.Args.Rule.ofEventRule(cloudwatchEventRule),
            ~arn=heartbeatLambda##arn->Pulumi.Output.asInput,
            (),
          ),
        //~opts=opts->Obj.magic, // TODO: is ComponentResource.Options still relevant in today's Pulumi version
        (),
      )
    );
  let _ =
    cloudwatchEventRule##arn
    ->Pulumi.Output.apply(ruleArn => {
        let _heartbeatLambdaPermission =
          PulumiAws.Lambda.(
            Permission.make(
              ~name=heartbeatName,
              ~args=
                Permission.Args.make(
                  ~_function=heartbeatLambda##arn->Pulumi.Output.asInput,
                  ~action="lambda:InvokeFunction",
                  ~principal="events.amazonaws.com",
                  ~sourceArn=ruleArn,
                  (),
                ),
              /* TODO: opts */
              (),
            )
          );
        ();
      });

  makeOutputs(~name, ~cloudwatchEventRule, ~cloudwatchEventTarget)
  |> self->setOutputs;
};

let make = (~id, ~name, ~timeout=10, ~commandTopicId, ~opts=?, _) =>
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name,
    ~construct=construct(~id, ~timeout, ~commandTopicId),
    ~opts,
  );
