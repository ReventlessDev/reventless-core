// TODO: refactor to abstractions
let componentType = ComponentType.Task;

type publishCommands =
  (. /*~aggregateName:*/ string, array(Message.commandJson)) =>
  Js.Promise.t(unit);

type outputs = {
  .
  "name": string,
  "bucket": option(PulumiAws.S3.Bucket.bucket),
  "sideEffectHandler": option(SideEffectHandler.outputs),
};

type t;
type component = Component.t(t, outputs);

type queryBucketName = string => string;

type maker =
  (
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.t,
    ~publishToAggregates: Js.Dict.t(CommandTopic.publishJsons),
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~allAggregates: Js.Dict.t(Aggregate.outputs),
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  component;

type setup =
  (
    . ReventlessSpec.QueryEngine.t,
    Scheduler.t,
    publishCommands,
    queryBucketName,
    EventTopic.allOutputs,
    Pulumi.CustomResourceOptions.t
  ) =>
  outputs;

type constructed;
type construct = (component, string) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  component =
  "default";

[@bs.send]
external registerOutputs: (component, outputs) => constructed =
  "registerOutputs";
[@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

let construct =
    (
      ~setup: setup,
      ~queryBucketName,
      ~scheduler: Scheduler.t,
      ~publishToAggregates,
      ~queryEngine,
      ~allAggregates,
      self,
      _name,
    ) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Component.toPulumiResource,
      (),
    );

  let publishCommands: publishCommands =
    (. aggregateName, cmdJsons) => {
      let count = cmdJsons->Belt.Array.size;
      cmdJsons->Belt.Array.forEachWithIndex((idx, {Message.id, commandJson}) => {
        let idx = idx + 1;
        let messageBody = commandJson->Js.Json.stringify;
        Js.log({j|Task.publishCommands $idx/$count: id=$id, $messageBody|j});
      });
      publishToAggregates
      ->Js.Dict.get(aggregateName)
      ->Belt.Option.getExn(. cmdJsons);
    };

  setup(.
    queryEngine,
    scheduler,
    publishCommands,
    queryBucketName,
    Util.Aggregate.allEventTopics(allAggregates),
    opts,
  )
  ->setOutputs(self, _);
};

let make =
    (
      ~name,
      ~setup,
      ~queryBucketName,
      ~scheduler,
      ~publishToAggregates,
      ~queryEngine,
      ~allAggregates,
      ~opts,
    ) => {
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name=name->ComponentType.name(componentType),
    ~construct=
      construct(
        ~setup,
        ~queryBucketName,
        ~scheduler,
        ~publishToAggregates,
        ~queryEngine,
        ~allAggregates,
      ),
    ~opts,
  );
};
