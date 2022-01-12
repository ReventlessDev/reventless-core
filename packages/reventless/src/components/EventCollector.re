open ReventlessSpec.Adapter;

let componentType = ComponentType.EventCollector;

type enqueueEvent =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type outputs = {. "resources": array(resource)};

type eventsHandler = (. array(Js.Json.t)) => Js.Promise.t(unit);

type arn = string;
module type Policies = {let policies: array(Pulumi.Output.t(arn));};
module DefaultPolicies: Policies = {
  let policies =
    PulumiAws.Lambda.Policy.defaultPolicies->Belt.Array.map(policy =>
      Pulumi.Output.make(policy)
    );
};

module type T = {
  type t;
  let make:
    (
      ~name: string,
      ~eventTopics: Js.Dict.t(EventTopic.outputs),
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    Component.t(t, outputs);

  let enqueueEvent: Component.t(t, outputs) => enqueueEvent;
};

module Adapter = {
  type connector = {
    resources: array(resource),
    enqueueEvent,
  };
  type connectorMaker =
    (
      ~name: string,
      ~eventTopics: Js.Dict.t(EventTopic.outputs),
      ~policies: array(Pulumi.Output.t(arn)),
      ~handleEvents: eventsHandler,
      ~memorySize: int,
      ~timeout: int,
      ~opts: Pulumi.CustomResourceOptions.t
    ) =>
    connector;

  module type Connector = {let make: connectorMaker;};
};

module Make = (Policies: Policies, Connector: Adapter.Connector) : T => {
  type t;
  type constructed;
  type construct = (Component.t(t, outputs), string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs: (~resources: array(resource)) => outputs = "";
  [@bs.send]
  external registerOutputs: (Component.t(t, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(t, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set]
  external setEnqueueEvent: (Component.t(t, outputs), enqueueEvent) => unit =
    "enqueueEvent";
  [@bs.get]
  external enqueueEvent: Component.t(t, outputs) => enqueueEvent =
    "enqueueEvent";

  let enqueueEventFn = connector =>
    (. delay, id, message) =>
      connector.Adapter.enqueueEvent(. delay, id, message);

  let construct =
      (~eventTopics, ~eventsHandler, ~memorySize, ~timeout, self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let connector =
      Connector.make(
        ~name=name->ComponentType.name(componentType),
        ~eventTopics,
        ~policies=Policies.policies,
        ~handleEvents=eventsHandler,
        ~memorySize,
        ~timeout,
        ~opts,
      );

    self->setEnqueueEvent(connector->enqueueEventFn);

    makeOutputs(~resources=connector.resources)->setOutputs(self, _);
  };

  let make:
    (
      ~name: string,
      ~eventTopics: Js.Dict.t(EventTopic.outputs),
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    Component.t(t, outputs) =
    (
      ~name,
      ~eventTopics,
      ~eventsHandler,
      ~memorySize=128,
      ~timeout=30,
      ~opts,
      _,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=
          construct(~eventTopics, ~eventsHandler, ~memorySize, ~timeout),
        ~opts,
      );
};
