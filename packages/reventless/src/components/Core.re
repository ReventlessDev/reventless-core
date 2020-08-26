let componentType = ComponentType.Core;

type extensionPointMakers = array(ExtensionPoint.maker);
type serviceMakers = array(Service.maker);

type outputs = {
  .
  "eventCollector": EventCollector.outputs,
  "extensionPoints": array(ExtensionPoint.t),
  "services": array(Service.t),
};
type t = outputs;

module Make = (EventCollectorAdapter: EventCollector.Connector) => {
  type constructed;
  type construct = (t, string) => constructed;

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

  [@bs.obj]
  external makeOutputs:
    (
      ~eventCollector: Reventless.EventCollector.t,
      ~extensionPoints: array(ExtensionPoint.t),
      ~services: array(Service.t)
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
        self,
        name,
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
          ~queryEventTopic,
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
        ~name,
        ~aggregateNames,
        ~eventHandler,
        ~queryEventTopic,
        ~opts=Some(opts),
        (),
      );

    makeOutputs(~eventCollector, ~extensionPoints, ~services)
    |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~extensionPointMakers: extensionPointMakers,
      ~serviceMakers: serviceMakers,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    t =
    (~name, ~extensionPointMakers, ~serviceMakers, ~opts=?, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name ++ "-" ++ Pulumi.Pulumi.getStackName(),
        ~construct=construct(~extensionPointMakers, ~serviceMakers),
        ~opts,
      );
};
