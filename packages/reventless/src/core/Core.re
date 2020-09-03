let componentType = ComponentType.Core;

type extensionPointMakers = array(ExtensionPoint.maker);
type serviceMakers = array(Service.maker);

type outputs = {
  .
  "eventCollector": EventCollector.t,
  "extensionPoints": Js.Dict.t(ExtensionPoint.t),
  "services": Js.Dict.t(Service.t),
};
type t = outputs;

let toDict = els =>
  els->Belt.Array.map(el => (el##name, el))->Js.Dict.fromArray;

module Make = (EventCollectorAdapter: EventCollector.Connector) => {
  type constructed;
  type construct = (t, string) => constructed;

  [@bs.module "../components/Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    t =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~eventCollector: EventCollector.t,
      ~extensionPoints: Js.Dict.t(ExtensionPoint.t),
      ~services: Js.Dict.t(Service.t)
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
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
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let services =
      serviceMakers->Belt.Array.map(serviceMaker =>
        serviceMaker(Some(opts))
      );

    let queryCommandTopic =
      InterstackResourceQueryRuntime.commandTopicConnectorOfAllServicesExn(
        services->Interstack.mergeServices,
      );
    let queryEventTopic =
      InterstackResourceQueryDeploytime.eventTopicPublisherOfAllServicesExn(
        services,
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

    module Set = Belt.Set.String;

    let aggregateNames: array(string) =
      extensionPoints
      ->Belt.Array.map(extensionPoint =>
          extensionPoint##aggregateNames->Set.fromArray
        )
      ->Belt.Array.reduce(Set.empty, Set.union)
      ->Belt.Set.String.toArray;

    let eventHandler =
      (. event'Json) =>
        extensionPoints->Belt.Array.map(extensionPoint => {
          let handle = extensionPoint##eventHandler;
          handle(. event'Json);
        })
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());

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
      ~eventCollector,
      ~extensionPoints=extensionPoints->toDict,
      ~services=services->toDict,
    )
    |> self->setOutputs;
  };

  let make:
    (
      ~extensionPointMakers: extensionPointMakers,
      ~serviceMakers: serviceMakers,
      ~scheduler: Scheduler.t
    ) =>
    t =
    (~extensionPointMakers, ~serviceMakers, ~scheduler) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name="Core",
        ~construct=
          construct(~extensionPointMakers, ~serviceMakers, ~scheduler),
        ~opts=None,
      );
};
