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

type queryBucketName = string => string;

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
    ~sideEffects: SideEffectHandler.sideEffects,
    (module SideEffectHandler.T)
  ) =>
  SideEffectHandler.outputs;

type setup =
  (
    . queryBucketName,
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
      ~setup: setup,
      ~queryBucketName,
      ~scheduler: Scheduler.t,
      ~queryEngine,
      self,
      name,
      resources,
    ) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Component.toPulumiResource,
      (),
    );

  let createSideEffectHandler: createSideEffectHandler =
    (~sideEffects, (module SideEffectHandler)) =>
      SideEffectHandler.make(
        ~name,
        ~sideEffects,
        ~queryEngine,
        ~scheduler,
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

  setup(. queryBucketName, createSideEffectHandler, opts)
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
    ~construct=construct(~setup, ~queryBucketName, ~scheduler, ~queryEngine),
    ~opts,
    ~resources,
  );
};
