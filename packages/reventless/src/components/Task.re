// TODO: refactor to abstractions
open ReventlessSpec.Adapter;

let componentType = ComponentType.Task;

type publishCommands =
  (
    . /*~queueName:*/ string,
    array((/*~id:*/ string, /*~meta*/ Message.meta, /*~message:*/ string))
  ) =>
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
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources
  ) =>
  component;

type setup =
  (
    . ReventlessSpec.QueryEngine.t,
    Scheduler.t,
    publishCommands,
    queryBucketName,
    Js.Dict.t(EventTopic.outputs),
    Pulumi.CustomResourceOptions.t,
    resources
  ) =>
  outputs;

type constructed;
type construct = (component, string, resources) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources
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
      ~queryEngine,
      ~allAggregates,
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
      // TODO: move to Adapter
      let count = entries->Belt.Array.size;
      let connector =
        resources->Util.Aggregate.commandTopicConnectorResource(queueName);
      entries
      ->Belt.Array.mapWithIndex((idx, (id, meta: Message.meta, messageBody)) => {
          let idx = idx + 1;
          Js.log({j|Task.publishCommands $idx/$count: $messageBody|j});
          switch (connector##service->Pulumi.Output.get) {
          | "SQS_FIFO" =>
            AwsSdk.SQS.makeBatchEntryFifo(
              ~groupId=id,
              ~messageBody,
              ~messageId=meta.msgId,
              ~delay=None,
            )
          | _ =>
            AwsSdk.SQS.makeBatchEntry(
              ~messageBody,
              ~messageId=meta.msgId,
              ~delay=None,
            )
          };
        })
      ->AwsSdk.SQS.sendMessageBatch(
          ~queueId=connector##id->OutputFailsafeRuntime.get,
        )
      ->Util.Promise.allSettled
      |> Js.Promise.then_(results => {
           results
           ->Util.Promise.filterRejected
           ->Belt.Array.forEach(((idx, reason)) =>
               Js.log({j|SQS.sendMessageBatch request $idx failed: $reason|j})
             );
           Js.Promise.resolve(); // TODO: error handling
         })
      |> Js.Promise.catch(err =>
           Js.Promise.resolve(Js.log2("Task.publishCommands Error:", err))
         );
    };

  setup(.
    queryEngine,
    scheduler,
    publishCommands,
    queryBucketName,
    Util.Aggregate.allEventTopics(allAggregates),
    opts,
    resources,
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
      ~allAggregates,
      ~opts,
      ~resources,
    ) => {
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name=name->ComponentType.name(componentType),
    ~construct=
      construct(
        ~setup,
        ~queryBucketName,
        ~scheduler,
        ~queryEngine,
        ~allAggregates,
      ),
    ~opts,
    ~resources,
  );
};
