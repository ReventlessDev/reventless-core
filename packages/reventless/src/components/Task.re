// TODO: refactor to abstractions

let componentType = ComponentType.Task;

type outputs = {
  .
  "name": string,
  "bucket": option(PulumiAws.S3.Bucket.bucket),
  "mappings": option(module EventMapping.Mappings),
  "policies": option(module EventCollector.Policies),
};

type t = outputs;

type query =
  (
    . /*~tableName:*/ string,
    /*~key:*/ string,
    /*~value:*/ AwsSdk.DynamoDb.DocumentClient.QueryInput.value,
    /*~filters:*/ list(
      (
        string,
        AwsSdk.DynamoDb.DocumentClient.QueryInput.comparator,
        AwsSdk.DynamoDb.DocumentClient.QueryInput.value,
      ),
    ),
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
    ~queryQueryDb: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventCollector: InterstackResourceQuery.runtimeQueryExn,
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.t,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  t;

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
type construct = (t, string) => constructed;

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
  t =
  "default";

[@bs.send] external registerOutputs: (t, outputs) => constructed = "";
[@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

[@bs.val] [@bs.scope "JSON"] external parseJs: string => Js.t(_) = "parse";
let construct =
    (
      ~taskName,
      ~setup: setup,
      ~queryCommandTopic,
      ~queryQueryDb,
      ~queryEventCollector,
      ~queryBucketName,
      ~scheduler: Scheduler.t,
      self,
      _,
    ) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Pulumi.Resource.makeFromJs,
      (),
    );

  let toJson =
    fun
    | AwsSdk.DynamoDb.DocumentClient.QueryInput.String(str) =>
      Js.Json.string(str)
    | Int(int) => Js.Json.number(float_of_int(int))
    | Bool(bool) => Js.Json.boolean(bool);

  let createFilters = filters =>
    filters
    |> List.mapi((idx, (key, comparator, value)) => {
         let valueName = {j|$key$idx|j};
         (
           AwsSdk.DynamoDb.DocumentClient.QueryInput.(
             switch (comparator) {
             | Equal => {j|#$key = :$valueName|j}
             | Unequal => {j|#$key <> :$valueName|j}
             | LessOrEqual => {j|#$key <= :$valueName|j}
             | Less => {j|#$key < :$valueName|j}
             | GreaterOrEqual => {j|#$key >= :$valueName|j}
             | Greater => {j|#$key > :$valueName|j}
             //| Between => {j|#$filterKey between :$valueName and :$valueName|j}
             | Exists => {j|attribute_exists( #$key )|j}
             | NotExists => {j|attribute_not_exists( #$key )|j}
             | Contains => {j|contains( #$key, :$valueName )|j}
             | NotContains => {j|NOT contains( #$key, :$valueName )|j}
             | BeginsWith => {j|begins_with( #$key, :$valueName )|j}
             }
           ),
           (({j|#$key|j}, key), ({j|:$valueName|j}, value |> toJson)),
         );
       })
    |> Belt.List.unzip;
  open Js.Promise;

  let query =
    (. serviceName, key, value, filterConfigs, ascending, limit) => {
      let tableName =
        queryQueryDb(serviceName)##name->OutputFailsafeRuntime.get;

      let (filterExpressions, filterNamesValues) =
        filterConfigs |> createFilters;
      let filterExpression =
        switch (filterExpressions) {
        | [] => None
        | filterExpressions =>
          Some(filterExpressions |> String.concat(" AND "))
        };

      let (filterNames, filterValues) = filterNamesValues |> Belt.List.unzip;
      let attributeValues =
        [(":value", value |> toJson)]
        @ filterValues
        |> Js.Dict.fromList
        |> Js.Json.object_
        |> Js.Json.stringify
        |> parseJs;

      let attributeNames = [("#key", key)] @ filterNames |> Js.Dict.fromList;

      let params =
        AwsSdk.DynamoDb.DocumentClient.QueryInput.make(
          ~_TableName=tableName,
          ~_IndexName=?
            if (key == "id") {
              None;
            } else {
              Some(key);
            },
          ~_KeyConditionExpression="#key = :value",
          ~_FilterExpression=?filterExpression,
          ~_ExpressionAttributeNames=attributeNames,
          ~_ExpressionAttributeValues=attributeValues,
          ~_ScanIndexForward=ascending,
          ~_Limit=limit,
          (),
        );
      AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params)
      |> then_(result =>
           resolve(
             result##_Items
             |> Array.map(js => js |> Message.stringify |> Js.Json.parseExn),
           )
         )
      |> catch(err => {
           Js.log2("Task.query error:", err);
           resolve([||]);
         });
    };

  let publishCommand =
    (. queueName, messageBody) => {
      let queueId =
        queryCommandTopic(queueName)##id->OutputFailsafeRuntime.get;
      AwsSdk.SQS.sendMessage(~queueId, ~messageBody, ())
      |> then_(res => {
           Js.log({j|Task.publishCommand successfull: $messageBody|j});
           res |> resolve;
         })
      |> catch(err => resolve(Js.log2("Task.publishCommand error:", err)));
    };

  let forTaskQueue = (name, queueId) =>
    name ++ "-" ++ (queueId |> Js.String.split("-"))[1];

  let createSchedule =
    (. taskName) =>
      (. schedule: Scheduler.schedule) => {
        let eventCollector = queryEventCollector(taskName);
        let queueId = eventCollector##name->OutputFailsafeRuntime.get;
        let name = schedule.name->forTaskQueue(queueId);
        let schedule = {...schedule, name};
        let target =
          Scheduler.{
            id: eventCollector##name |> Pulumi.Output.get,
            urn: eventCollector##urn |> Pulumi.Output.get,
          };
        let createSchedule = scheduler##createSchedule;
        createSchedule(. target, schedule)
        |> Js.Promise.then_(_ =>
             Js.log4(
               "Task.createSchedule: created",
               schedule,
               queueId,
               target,
             )
             |> Js.Promise.resolve
           )
        |> Js.Promise.catch(err => {
             Js.log4(
               "Task.createSchedule: couldn't create",
               schedule,
               queueId,
               err,
             );
             ScheduleNotCreated(schedule, queueId, err)->Js.Promise.reject;
           });
      };

  let deleteSchedule =
    (. taskName) =>
      (. name) => {
        let eventCollector = queryEventCollector(taskName);
        let queueId = eventCollector##name->OutputFailsafeRuntime.get;
        let name = name->forTaskQueue(queueId);
        let target =
          Scheduler.{
            id: eventCollector##name |> Pulumi.Output.get,
            urn: eventCollector##urn |> Pulumi.Output.get,
          };
        let deleteSchedule = scheduler##deleteSchedule;
        deleteSchedule(. target, name)
        |> Js.Promise.then_(_ =>
             Js.log3("Task.deleteSchedule: deleted", name, queueId)
             |> Js.Promise.resolve
           )
        |> Js.Promise.catch(err => {
             Js.log4(
               "Task.deleteSchedule: couldn't delete",
               name,
               queueId,
               err,
             );
             ScheduleNotDeleted(name, queueId, err)->Js.Promise.reject;
           });
      };

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
  |> self->setOutputs;
};

let make =
    (
      ~name,
      ~setup,
      ~queryCommandTopic,
      ~queryQueryDb,
      ~queryEventCollector,
      ~queryBucketName,
      ~scheduler,
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
        ~queryQueryDb,
        ~queryEventCollector,
        ~queryBucketName,
        ~scheduler,
      ),
    ~opts,
  );
};