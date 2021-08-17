// TODO: refactor to abstractions
open ReventlessSpec.Adapter;

let componentType = ComponentType.Task;

type outputs = {
  .
  "name": string,
  "bucket": option(PulumiAws.S3.Bucket.bucket),
  "sideEffectHandler": option(SideEffectHandler.outputs),
};

type task; // TODO: rename to t - after refactoring

type publishCommands =
  (
    . /*~queueName:*/ string,
    array((/*~id:*/ string, /*~meta*/ Message.meta, /*~message:*/ string))
  ) =>
  Js.Promise.t(unit);

type queryBucketName = string => string;

type queueMessage =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type maker =
  (
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.t,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources
  ) =>
  Component.t(task, outputs);

type createSideEffectHandler =
  (
    ~name: string,
    ~sideEffects: SideEffectHandler.sideEffects,
    (module SideEffectHandler.T)
  ) =>
  SideEffectHandler.outputs;

type setup =
  (
    . ReventlessSpec.QueryEngine.t,
    publishCommands,
    queryBucketName,
    ReventlessSpec.Schedule.create,
    ReventlessSpec.Schedule.delete,
    queueMessage,
    createSideEffectHandler,
    Pulumi.CustomResourceOptions.t
  ) =>
  outputs;

type constructed;
type construct =
  (Component.t(task, outputs), string, resources) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources
  ) =>
  Component.t(task, outputs) =
  "default";

[@bs.send]
external registerOutputs: (Component.t(task, outputs), outputs) => constructed =
  "registerOutputs";
[@bs.send]
external setOutputs: (Component.t(task, outputs), outputs) => unit =
  "setOutputs";
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

let construct =
    (
      ~taskName,
      ~setup: setup,
      ~queryBucketName,
      ~scheduler: Scheduler.t,
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      self,
      _name,
      resources,
    ) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Component.toPulumiResource,
      (),
    );

  let publishCommands =
    (. queueName, entries) => {
      let count = entries->Belt.Array.size;
      entries
      ->Belt.Array.mapWithIndex((idx, (id, meta: Message.meta, messageBody)) => {
          Js.log({j|Task.publishCommands $idx/$count: $messageBody|j});
          AwsSdk.SQS.makeBatchEntry(
            // TODO: move to Adapter
            ~groupId=id,
            ~messageBody,
            ~messageId=meta.msgId,
            ~delay=None,
          );
        })
      ->AwsSdk.SQS.sendMessageBatch(
          // TODO: move to Adapter
          ~queueId=
            resources->Util.Aggregate.commandTopicConnectorResource(queueName)##id
            ->OutputFailsafeRuntime.get,
        )
      |> Js.Promise.catch(err =>
           Js.Promise.resolve(Js.log2("Task.publishCommands Error:", err))
         );
    };

  let createSchedule =
    (. taskName) =>
      (. schedule: ReventlessSpec.Schedule.schedule) =>
        (
          Schedule.create(
            scheduler,
            resources->Util_EventCollector.getConnectorResource(taskName),
          )
        )(.
          schedule,
        );

  let deleteSchedule =
    (. taskName) =>
      (. name) =>
        (
          Schedule.delete(
            scheduler,
            resources->Util_EventCollector.getConnectorResource(taskName),
          )
        )(.
          name,
        );

  let queueMessage =
    (. taskName) =>
      (. delay, id, messageBody) => {
        let queueId =
          resources->Util_EventCollector.getConnectorResource(taskName)##id
          ->OutputFailsafeRuntime.get;
        Js.log4("Task.queueMessage:", delay, messageBody, queueId);
        AwsSdk.SQS.sendMessage(
          // TODO: move to Adapter
          ~queueId,
          // ~messageGroupId=id,
          ~messageBody,
          ~delay,
          (),
        );
      };

  let createSideEffectHandler: createSideEffectHandler =
    (~name, ~sideEffects, (module SideEffectHandler)) =>
      SideEffectHandler.make(
        ~name,
        ~sideEffects,
        ~queryEngine,
        ~opts=
          Some(
            Pulumi.ComponentResource.Options.make(
              ~parent=self->Component.toPulumiResource,
              (),
            ),
          ),
        ~resources,
        (),
      )
      ->Component.extractOutputs;

  setup(.
    queryEngine,
    publishCommands,
    queryBucketName,
    createSchedule(. taskName),
    deleteSchedule(. taskName),
    queueMessage(. taskName),
    createSideEffectHandler,
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
      ~queryEngine,
      ~opts,
      ~resources,
    ) => {
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name=name->ComponentType.name(componentType),
    ~construct=
      construct(
        ~taskName=name,
        ~setup,
        ~queryBucketName,
        ~scheduler,
        ~queryEngine,
      ),
    ~opts,
    ~resources,
  );
};
