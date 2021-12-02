open ReventlessSpec.Adapter;

let componentType = ComponentType.Core;

type extensionPointMakers = array(ExtensionPoint.maker);
type serviceMakers = array(Service.maker);

type outputs = {
  .
  "version": string,
  "eventCollector": EventCollector.outputs,
  "extensionPoints": Js.Dict.t(ExtensionPoint.outputs),
  "services": Js.Dict.t(Service.outputs),
  "cloner": Cloner.outputs,
  "resources": resources,
};
type core;

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
  type construct = (Component.t(core, outputs), string) => constructed;

  [@bs.module "../components/Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(core, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~version: string,
      ~eventCollector: EventCollector.outputs,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.outputs),
      ~services: Js.Dict.t(Service.outputs),
      ~cloner: Cloner.outputs,
      ~resources: resources
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs:
    (Component.t(core, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(core, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct =
      (
        ~version,
        ~extensionPointMakers: extensionPointMakers,
        ~serviceMakers: serviceMakers,
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

    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(~opts, ~resources, ())
      );
    let servicesOutputs = services->Component.extractMultipleOutputs;

    let extensionPoints =
      extensionPointMakers->Belt.Array.map(extensionPointMaker =>
        extensionPointMaker(
          ~scheduler,
          ~queryEngine=QueryEngineAdapter.make(resources),
          ~opts=Some(opts),
          ~resources,
          (),
        )
      );
    let extensionPointsOutputs =
      extensionPoints->Component.extractMultipleOutputs;

    module Set = Belt.Set.String;

    let aggregateNames: array(string) =
      extensionPointsOutputs
      ->Belt.Array.map(extensionPoint =>
          extensionPoint##aggregateNames->Set.fromArray
        )
      ->Belt.Array.reduce(Set.empty, Set.union)
      ->Belt.Set.String.toArray;

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
        ~aggregateNames,
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
      ~services=servicesOutputs->toDict,
      ~cloner=cloner->Component.extractOutputs,
      ~resources,
    )
    ->setOutputs(self, _);
  };

  let make:
    (
      ~version: string,
      ~extensionPointMakers: extensionPointMakers,
      ~serviceMakers: serviceMakers,
      ~scheduler: Scheduler.t
    ) =>
    Component.t(core, outputs) =
    (~version, ~extensionPointMakers, ~serviceMakers, ~scheduler) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name="Core",
        ~construct=
          construct(
            ~version,
            ~extensionPointMakers,
            ~serviceMakers,
            ~scheduler,
          ),
        ~opts=None,
      );
};
