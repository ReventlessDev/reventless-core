// TODO: refactor to abstractions

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
    ~opts: option(Pulumi.ComponentResource.Options.t)
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
type construct = (Component.t(task, outputs), string) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t)
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
      _,
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
            ~groupId=id,
            ~messageBody,
            ~messageId=meta.msgId,
            ~delay=None,
          );
        })
      ->AwsSdk.SQS.sendMessageBatch(
          ~queueId=
            queueName->CommandTopic.Adapter.getResource##id
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
            taskName->EventCollector.Adapter.getResource,
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
            taskName->EventCollector.Adapter.getResource,
          )
        )(.
          name,
        );

  let queueMessage =
    (. taskName) =>
      (. delay, id, messageBody) => {
        let queueId =
          taskName->EventCollector.Adapter.getResource##id
          ->OutputFailsafeRuntime.get;
        Js.log4("Task.queueMessage:", delay, messageBody, queueId);
        AwsSdk.SQS.sendMessage(
          ~queueId,
          ~messageGroupId=id,
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

let make = (~name, ~setup, ~queryBucketName, ~scheduler, ~queryEngine, ~opts) => {
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
  );
};
