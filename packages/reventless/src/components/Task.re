// TODO: refactor to abstractions

let componentType = ComponentType.Task;

type outputs = {
  .
  "name": string,
  "bucket": option(PulumiAws.S3.Bucket.bucket),
  "mappings": option(module ReventlessSpec.EventMapping.T), // FIXME: this is incorrect: Previously several Aggregates' events could be mapped to a Task
  "policies": option(module EventCollector.Policies),
};

type task; // TODO: rename to t - after refactoring

open ReventlessSpec;

type publishCommand =
  (. /*~queueName:*/ string, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type queryBucketName = string => string;

type createSchedule = (. Scheduler.schedule) => Js.Promise.t(unit);
type deleteSchedule = (. /*~name:*/ string) => Js.Promise.t(unit);

type queueMessage =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type maker =
  (
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventCollector: InterstackResourceQuery.runtimeQueryExn,
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.t,
    ~queryEngine: QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  Component.t(task, outputs);

type setup =
  (
    . QueryEngine.t,
    publishCommand,
    queryBucketName,
    createSchedule,
    deleteSchedule,
    queueMessage,
    Pulumi.CustomResourceOptions.t
  ) =>
  outputs;

type constructed;
type construct = (Component.t(task, outputs), string) => constructed;

exception ScheduleNotCreated(Scheduler.schedule, string, Js.Promise.error);
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
      ~queryBucketName,
      ~scheduler: Scheduler.t,
      ~queryEngine: QueryEngine.t,
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
      (. schedule: Scheduler.schedule) =>
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

  setup(.
    queryEngine,
    publishCommand,
    queryBucketName,
    createSchedule(. taskName),
    deleteSchedule(. taskName),
    queueMessage(. taskName),
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
        ~queryBucketName,
        ~scheduler,
        ~queryEngine,
      ),
    ~opts,
  );
};
