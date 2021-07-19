// TODO: refactor to abstractions

let componentType = ComponentType.Task;

type outputs = {
  .
  "name": string,
  "bucket": option(PulumiAws.S3.Bucket.bucket),
  "sideEffectHandler": option(SideEffectHandler.outputs),
};

type task; // TODO: rename to t - after refactoring

type publishCommand =
  (. /*~queueName:*/ string, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type queryBucketName = string => string;

type createSchedule =
  (. ReventlessSpec.Scheduler.schedule) => Js.Promise.t(unit);
type deleteSchedule = (. /*~name:*/ string) => Js.Promise.t(unit);

type queueMessage =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type maker =
  (
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventCollector: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
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
  SideEffectHandler.sideEffectHandlerComponent;

type setup =
  (
    . ReventlessSpec.QueryEngine.t,
    publishCommand,
    queryBucketName,
    createSchedule,
    deleteSchedule,
    queueMessage,
    createSideEffectHandler,
    Pulumi.CustomResourceOptions.t
  ) =>
  outputs;

type constructed;
type construct = (Component.t(task, outputs), string) => constructed;

exception
  ScheduleNotCreated(
    ReventlessSpec.Scheduler.schedule,
    string,
    Js.Promise.error,
  );
exception ScheduleNotDeleted(string, string, Js.Promise.error);

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
      ~queryCommandTopic,
      ~queryEventCollector,
      ~queryEventTopic,
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

  let publishCommand =
    (. queueName, id, messageBody) => {
      let queueId =
        queryCommandTopic(queueName)##id->OutputFailsafeRuntime.get;
      AwsSdk.SQS.sendMessage(~queueId, ~messageGroupId=id, ~messageBody, ())
      |> Js.Promise.then_(res => {
           Js.log({j|Task.publishCommand successfull: $messageBody|j});
           res |> Js.Promise.resolve;
         })
      |> Js.Promise.catch(err =>
           Js.Promise.resolve(Js.log2("Task.publishCommand Error:", err))
         );
    };

  let createSchedule =
    (. taskName) =>
      (. schedule: ReventlessSpec.Scheduler.schedule) =>
        (Schedule.create(scheduler, queryEventCollector(taskName)))(.
          schedule,
        );

  let deleteSchedule =
    (. taskName) =>
      (. name) =>
        (Schedule.delete(scheduler, queryEventCollector(taskName)))(. name);

  let queueMessage =
    (. taskName) =>
      (. delay, id, messageBody) => {
        let eventCollector = queryEventCollector(taskName);
        let queueId = eventCollector##id->OutputFailsafeRuntime.get;
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
        ~queryEventTopic,
        ~memorySize=2048,
        ~opts=
          Some(
            Pulumi.ComponentResource.Options.make(
              ~parent=self->Component.toPulumiResource,
              (),
            ),
          ),
        (),
      );

  setup(.
    queryEngine,
    publishCommand,
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
      ~queryCommandTopic,
      ~queryEventCollector,
      ~queryEventTopic,
      ~queryBucketName,
      ~scheduler,
      ~queryEngine,
      ~opts,
    ) => {
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name=name->ComponentType.name(componentType),
    ~construct=
      construct(
        ~taskName=name,
        ~setup,
        ~queryCommandTopic,
        ~queryEventCollector,
        ~queryEventTopic,
        ~queryBucketName,
        ~scheduler,
        ~queryEngine,
      ),
    ~opts,
  );
};
