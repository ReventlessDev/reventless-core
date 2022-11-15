open ReventlessSpec.Adapter;

let componentType = ComponentType.EventCollector;

type enqueueEvent =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type outputs = {
  .
  "name": string,
  "resources": array(resource),
};

type eventsHandler = (. array(Js.Json.t)) => Js.Promise.t(unit);

module type T = {
  type t;
  let make:
    (
      ~name: string,
      ~eventTopics: Js.Dict.t(EventTopic.outputs),
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~policy1: Pulumi.Output.t(string)=?,
      ~policy2: Pulumi.Output.t(string)=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources,
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
      ~handleEvents: eventsHandler,
      ~memorySize: int,
      ~timeout: int,
      ~policy1: Pulumi.Output.t(string)=?,
      ~policy2: Pulumi.Output.t(string)=?,
      ~opts: Pulumi.CustomResourceOptions.t
    ) =>
    connector;

  module type Connector = {let make: connectorMaker;};
};

module Make = (Connector: Adapter.Connector) : T => {
  type t;
  type constructed;
  type construct =
    (Component.t(t, outputs), string, resources) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (~name: string, ~resources: array(resource)) => outputs =
    "";
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
      (
        ~eventTopics,
        ~eventsHandler,
        ~memorySize,
        ~timeout,
        ~policy1=?,
        ~policy2=?,
        self,
        name,
        resources,
      ) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let connector =
      Connector.make(
        ~name=name->ComponentType.name(componentType),
        ~eventTopics,
        ~policy1?,
        ~policy2?,
        ~handleEvents=eventsHandler,
        ~memorySize,
        ~timeout,
        ~opts,
      );
    switch (connector.resources) {
    | [||] => ()
    | connectorResources =>
      resources->Util_EventCollector.setConnectorResource(
        connectorResources[0],
        name,
      )
    };

    self->setEnqueueEvent(connector->enqueueEventFn);

    makeOutputs(~name, ~resources=connector.resources)->setOutputs(self, _);
  };

  let make =
      (
        ~name,
        ~eventTopics,
        ~eventsHandler,
        ~memorySize=128,
        ~timeout=30,
        ~policy1=?,
        ~policy2=?,
        ~opts,
        ~resources,
        _,
      ) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=
        construct(
          ~eventTopics,
          ~eventsHandler,
          ~memorySize,
          ~timeout,
          ~policy1?,
          ~policy2?,
        ),
      ~opts,
      ~resources,
    );
};
