open ReventlessSpec.Adapter;

let componentType = ComponentType.EventCollector;

type outputs = {. "connector": resource};

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
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    Component.t(t, outputs);
};

type connector = {resource};
type connectorMaker =
  (
    ~name: string,
    ~eventServices: array(string),
    ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
    ~policies: array(Pulumi.Output.t(arn)),
    ~handleEvents: eventsHandler,
    ~memorySize: int,
    ~timeout: int,
    ~opts: Pulumi.CustomResourceOptions.t
  ) =>
  connector;

module type Connector = {let make: connectorMaker;};

module Make = (Policies: Policies, Connector: Connector) : T => {
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

  [@bs.obj] external makeOutputs: (~connector: resource) => outputs = "";
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
      (
        ~aggregateNames,
        ~eventsHandler,
        ~queryEventTopic,
        ~memorySize,
        ~timeout,
        self,
        name,
      ) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let connector =
      Connector.make(
        ~name=name->ComponentType.name(componentType),
        ~eventServices=aggregateNames,
        ~queryEventTopic,
        ~policies=Policies.policies,
        ~handleEvents=eventsHandler,
        ~memorySize,
        ~timeout,
        ~opts,
      );

    makeOutputs(~connector=connector.resource)->setOutputs(self, _);
  };

  let make:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~eventsHandler: eventsHandler,
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
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
      ~queryEventTopic,
      ~memorySize=128,
      ~timeout=30,
      ~opts,
      _,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=
          construct(
            ~aggregateNames,
            ~eventsHandler,
            ~queryEventTopic,
            ~memorySize,
            ~timeout,
          ),
        ~opts,
      );
};
