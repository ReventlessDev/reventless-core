open ReventlessSpec.Adapter;

let componentType = ComponentType.EventCollector;

type enqueueEvent =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type outputs = {
  .
  "connector": option(resource),
  "func": resource,
};

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
      ~aggregateNames: array(string),
      ~extensionPointNames: array(string)=?,
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let enqueueEvent: Component.t(t, outputs) => enqueueEvent;
};

module Adapter = {
  type connector = {
    resource: option(resource),
    func: resource,
    enqueueEvent,
  };
  type connectorMaker =
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~extensionPointNames: array(string),
      ~policies: array(Pulumi.Output.t(arn)),
      ~handleEvents: eventsHandler,
      ~memorySize: int,
      ~timeout: int,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    connector;

  module type Connector = {let make: connectorMaker;};
};

module Make = (Policies: Policies, Connector: Adapter.Connector) : T => {
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
    (~connector: option(resource), ~func: resource) => outputs =
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
        ~aggregateNames,
        ~extensionPointNames,
        ~eventsHandler,
        ~memorySize,
        ~timeout,
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
        ~aggregateNames,
        ~extensionPointNames,
        ~policies=Policies.policies,
        ~handleEvents=eventsHandler,
        ~memorySize,
        ~timeout,
        ~opts,
        ~resources,
      );

    // resources->Util_EventCollector.setConnectorFunc(connector.func, name);
    switch (connector.resource) {
    | Some(resource) =>
      resources->Util_EventCollector.setConnectorResource(resource, name)
    | None => ()
    };

    self->setEnqueueEvent(connector->enqueueEventFn);

    makeOutputs(~connector=connector.resource, ~func=connector.func)
    ->setOutputs(self, _);
  };

  let make:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~extensionPointNames: array(string)=?,
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (
      ~name,
      ~aggregateNames,
      ~extensionPointNames=[||],
      ~eventsHandler,
      ~memorySize=128,
      ~timeout=30,
      ~opts,
      ~resources,
      _,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=
          construct(
            ~aggregateNames,
            ~extensionPointNames,
            ~eventsHandler,
            ~memorySize,
            ~timeout,
          ),
        ~opts,
        ~resources,
      );
};
