// TODO: refactor to abstractions

let componentType = ComponentType.Task;

type outputs = {
  .
  "name": string,
  "bucket": option(PulumiAws.S3.Bucket.bucket),
  "mappings": option(module EventMapping.Mappings),
  "policies": option(module EventCollector.Policies),
};

type task; // TODO: rename to t - after refactoring

type query =
  (
    . /*~serviceName:*/ string,
    /*~key:*/ string,
    /*~value:*/ QueryDb.value,
    /*~filters:*/ list((string, QueryDb.comparator, QueryDb.value)),
    /*~ascending*/ bool,
    /*~limit*/ int
  ) =>
  Js.Promise.t(array(Js.Json.t));

type publishCommand =
  (. /*~queueName:*/ string, /*~message:*/ string) => Js.Promise.t(unit);

type queryBucketName = string => string;

type createSchedule = (. Scheduler.schedule) => Js.Promise.t(unit);
type deleteSchedule = (. /*~name:*/ string) => Js.Promise.t(unit);

type queueMessage =
  (. /*~delay:*/ int, /*~message:*/ string) => Js.Promise.t(unit);

type maker =
  (
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventCollector: InterstackResourceQuery.runtimeQueryExn,
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.t,
    ~queryByServiceName: QueryDb.query,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  Component.t(task, outputs);

type setup =
  (
    . query,
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
      ~queryByServiceName: QueryDb.query,
      self,
      _,
    ) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Component.toPulumiResource,
      (),
    );

  let query =
    (. serviceName, key, value, filterConfigs, ascending, limit) =>
      queryByServiceName(
        ~serviceName,
        ~key,
        ~value,
        ~filterConfigs,
        ~ascending,
        ~limit,
      );

  let publishCommand =
    (. queueName, messageBody) => {
      let queueId =
        queryCommandTopic(queueName)##id->OutputFailsafeRuntime.get;
      AwsSdk.SQS.sendMessage(~queueId, ~messageBody, ())
      |> Js.Promise.then_(res => {
           Js.log({j|Task.publishCommand successfull: $messageBody|j});
           res |> Js.Promise.resolve;
         })
      |> Js.Promise.catch(err =>
           Js.Promise.resolve(Js.log2("Task.publishCommand error:", err))
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
      (. delay, messageBody) => {
        let eventCollector = queryEventCollector(taskName);
        let queueId = eventCollector##id->OutputFailsafeRuntime.get;
        Js.log4("Task.queueMessage:", delay, messageBody, queueId);
        AwsSdk.SQS.sendMessage(~queueId, ~messageBody, ~delay, ());
      };

  setup(.
    query,
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
      ~queryByServiceName,
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
        ~queryByServiceName,
      ),
    ~opts,
  );
};
