let componentType = ComponentType.Core;

type extensionPointMakers = array(ExtensionPoint.maker);
type serviceMakers = array(Service.maker);

type outputs = {
  .
  "eventCollector": EventCollector.outputs,
  "extensionPoints": Js.Dict.t(ExtensionPoint.outputs),
  "services": Js.Dict.t(Service.outputs),
};
type core;

let toDict = els =>
  els->Belt.Array.map(el => (el##name, el))->Js.Dict.fromArray;

module Make = (EventCollectorAdapter: EventCollector.Connector) => {
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
      ~eventCollector: EventCollector.outputs,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.outputs),
      ~services: Js.Dict.t(Service.outputs)
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

    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(Some(opts))
      );
    let servicesOutputs = services->Component.extractMultipleOutputs;

    let queryCommandTopic =
      InterstackResourceQueryRuntime.commandTopicConnectorOfAllServicesExn(
        servicesOutputs->Interstack.mergeServices,
      );
    let queryEventTopic =
      InterstackResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
        servicesOutputs,
      );

    let extensionPoints =
      extensionPointMakers->Belt.Array.map(extensionPointMaker =>
        extensionPointMaker(
          ~queryCommandTopic,
          ~scheduler,
          ~opts=Some(opts),
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
      name: "Core",
      version: "FAKE",
      extensionPoints: [||],
      extensions: [||],
      eventCollector: "NOT-SET",
    };

    let eventHandler =
      (. event'Json) => {
        event'Json->Message.logEvent'Json(
          "Core eventHandler: outgoing event:",
        );
        extensionPointsOutputs
        ->Belt.Array.map(extensionPoint => {
            let handle = extensionPoint##outgoingEventHandler;
            handle(. event'Json, fakePluginDefinition);
          })
        ->Js.Promise.all
        ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
      };

    module EventCollector =
      EventCollector.Make(EventCollector.NoPolicies, EventCollectorAdapter);

    let eventCollector =
      EventCollector.make(
        ~name="Core",
        ~aggregateNames,
        ~eventHandler,
        ~queryEventTopic,
        ~opts=Some(opts),
        (),
      );

    makeOutputs(
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~extensionPoints=extensionPointsOutputs->toDict,
      ~services=servicesOutputs->toDict,
    )
    ->setOutputs(self, _);
  };

  let make:
    (
      ~extensionPointMakers: extensionPointMakers,
      ~serviceMakers: serviceMakers,
      ~scheduler: Scheduler.t
    ) =>
    Component.t(core, outputs) =
    (~extensionPointMakers, ~serviceMakers, ~scheduler) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name="Core",
        ~construct=
          construct(~extensionPointMakers, ~serviceMakers, ~scheduler),
        ~opts=None,
      );
};
