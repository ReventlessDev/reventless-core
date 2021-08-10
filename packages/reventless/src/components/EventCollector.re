open ReventlessSpec.Adapter;

let componentType = ComponentType.EventCollector;

type outputs = {. "connector": option(resource)};

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
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    Component.t(t, outputs);
};

module Adapter = {
  let connector = "Connector";
  type connector = {resource: option(resource)};
  type connectorMaker =
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~policies: array(Pulumi.Output.t(arn)),
      ~handleEvents: eventsHandler,
      ~memorySize: int,
      ~timeout: int,
      ~opts: Pulumi.CustomResourceOptions.t
    ) =>
    connector;

  module type Connector = {let make: connectorMaker;};

  let setResource = (resource, name) =>
    Resources.set(~adapter=connector, ~name, ~resource);
  let getResource = name =>
    Resources.getExn(
      ~adapter=connector,
      ~name=name->ComponentType.name(componentType),
    );
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
  external makeOutputs: (~connector: option(resource)) => outputs = "";
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

  let construct =
      (~aggregateNames, ~eventsHandler, ~memorySize, ~timeout, self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let connector =
      Connector.make(
        ~name,
        ~aggregateNames,
        ~policies=Policies.policies,
        ~handleEvents=eventsHandler,
        ~memorySize,
        ~timeout,
        ~opts,
      );
    switch (connector.resource) {
    | Some(resource) => resource->Adapter.setResource(name)
    | None => Js.log2("No resource created for EventColllector", name)
    };

    makeOutputs(~connector=connector.resource)->setOutputs(self, _);
  };

  let make:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~eventsHandler: eventsHandler,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    Component.t(t, outputs) =
    (
      ~name,
      ~aggregateNames,
      ~eventsHandler,
      ~memorySize=128,
      ~timeout=30,
      ~opts,
      _,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name->ComponentType.name(componentType),
        ~construct=
          construct(~aggregateNames, ~eventsHandler, ~memorySize, ~timeout),
        ~opts,
      );
};
