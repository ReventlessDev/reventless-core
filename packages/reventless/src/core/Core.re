open ReventlessSpec.Adapter;

let componentType = ComponentType.Core;

type extensionPointMakers = array(ExtensionPoint.maker);

type outputs = {
  .
  "version": string,
  "eventCollector": EventCollector.outputs,
  "extensionPoints": Js.Dict.t(ExtensionPoint.outputs),
  "aggregates": Pulumi.Output.t(Js.Dict.t(Aggregate.outputs)),
  "readModels": Pulumi.Output.t(Js.Dict.t(ReadModel.outputs)),
  "cloner": Cloner.outputs,
  "resources": resources,
};

type t;
type component = Component.t(t, outputs);

type maker =
  (
    ~version: string,
    ~extensionPoints: array(module ExtensionPoint.T),
    ~aggregates: array(module Aggregate.T),
    ~readModels: array(module ReadModel.T),
    ~scheduler: Scheduler.t
  ) =>
  component;

module type T = {let make: maker;};

let toDict = els =>
  els->Belt.Array.map(el => (el##name, el))->Js.Dict.fromArray;

module Make =
       (
         Config: Config.T,
         EventCollectorConnector: EventCollector.Adapter.Connector,
         QueryEngineAdapter: QueryDb.Adapter.QueryEngineAdapter,
         ClonerRunner: Cloner.Adapter.Runner with type api := Config.api,
       ) => {
  type constructed;
  type construct = (component, string) => constructed;

  [@bs.module "../components/Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    component =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~version: string,
      ~eventCollector: EventCollector.outputs,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.outputs),
      ~aggregates: Js.Dict.t(Aggregate.outputs),
      ~readModels: Js.Dict.t(ReadModel.outputs),
      ~cloner: Cloner.outputs,
      ~resources: resources
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  type readModel = {
    module_: (module ReadModel.T),
    readModel: ReadModel.component,
  };

  let construct =
      (
        ~version,
        ~extensionPoints: array(module ExtensionPoint.T),
        ~aggregates: array(module Aggregate.T),
        ~readModels: array(module ReadModel.T),
        ~scheduler: Scheduler.t,
        self,
        _,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let resources: resources = Js.Dict.empty();

    let readModels =
      readModels
      ->Belt.Array.map((module ReadModel: ReadModel.T) =>
          (
            ReadModel.Spec.name,
            {
              module_: (module ReadModel),
              readModel: ReadModel.make(~opts, ~resources, ()),
            },
          )
        )
      ->Js.Dict.fromArray;
    let readModelsOutputs =
      readModels
      ->Js.Dict.values
      ->Belt.Array.map(({readModel}) => readModel)
      ->Component.extractMultipleOutputs;

    let queryEngine = QueryEngineAdapter.make(resources);

    let publishJsonsFns = Js.Dict.empty();
    let aggregatesOutputs =
      aggregates
      ->Belt.Array.map((module Aggregate: Aggregate.T) => {
          let {module_, readModel} =
            readModels->Js.Dict.unsafeGet(Aggregate.Spec.name);
          module ReadModel = (val module_);
          let aggregate =
            Aggregate.make(
              ~queryEngine,
              ~eventsHandler=
                (. id, events) =>
                  readModel->ReadModel.update(.
                    id->Obj.magic,
                    events->Obj.magic,
                  ), // TODO : remove
              ~opts,
              ~resources,
              (),
            );
          publishJsonsFns->Js.Dict.set(
            Aggregate.Spec.name,
            aggregate->Aggregate.publishJsons,
          );
          aggregate->Component.extractOutputs;
        })
      ->toDict;
    // TODO addEventMapperFns

    let extensionPoints =
      extensionPoints->Belt.Array.map(
        (module ExtensionPoint: ExtensionPoint.T) =>
        ExtensionPoint.make(
          ~publishJsonsFns,
          ~scheduler,
          ~queryEngine,
          ~opts=Some(opts),
          ~resources,
          (),
        )
      );
    let extensionPointsOutputs =
      extensionPoints->Component.extractMultipleOutputs;

    let aggregateNames =
      extensionPointsOutputs
      ->Belt.Array.map(extensionPoint =>
          extensionPoint##aggregateNames->Belt.Set.String.fromArray
        )
      ->Belt.Array.reduce(Belt.Set.String.empty, Belt.Set.String.union);

    let fakePluginDefinition: PluginSpec.pluginDefinition = {
      id: "Core@FAKE",
      name: "Core",
      version: "FAKE",
      extensionPoints: [||],
      extensions: [||],
      eventCollector: "NOT-SET",
    };

    let eventsHandler =
      (. events'Json) => {
        let count = events'Json->Belt.Array.size;
        events'Json
        ->Belt.Array.mapWithIndex((idx, event'Json) => {
            let idx = idx + 1;
            event'Json->Message.logEvent'Json(
              {j|Core eventHandler: outgoing event $idx/$count:|j},
            );
            extensionPointsOutputs
            ->Belt.Array.map(extensionPoint => {
                let handle = extensionPoint##outgoingEventHandler;
                handle(. event'Json, fakePluginDefinition);
              })
            ->Js.Promise.all
            ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
          })
        ->Js.Promise.all
        ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
      };

    module EventCollector =
      EventCollector.Make(
        EventCollector.DefaultPolicies,
        EventCollectorConnector,
      );

    let eventCollector =
      EventCollector.make(
        ~name=componentType->ComponentType.toName,
        ~eventTopics=
          Util.Aggregate.findEventTopics(aggregatesOutputs, aggregateNames),
        ~eventsHandler,
        ~opts=Some(opts),
        ~resources,
        (),
      );

    module Cloner = Cloner.Make(Config, ClonerRunner);
    let cloner = Cloner.make(~opts, ());

    makeOutputs(
      ~version,
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~extensionPoints=extensionPointsOutputs->toDict,
      ~aggregates=aggregatesOutputs,
      ~readModels=readModelsOutputs->toDict,
      ~cloner=cloner->Component.extractOutputs,
      ~resources,
    )
    ->setOutputs(self, _);
  };

  let make: maker =
    (~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name="Core",
        ~construct=
          construct(
            ~version,
            ~extensionPoints,
            ~aggregates,
            ~readModels,
            ~scheduler,
          ),
        ~opts=None,
      );
};
