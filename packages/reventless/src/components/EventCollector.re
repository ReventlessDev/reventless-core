let componentType = ComponentType.EventCollector;

type eventHandler = (. Js.Json.t) => Js.Promise.t(unit);

type outputs = {. "connector": Adapter.resource};
type t = outputs;

type arn = string;
module type Policies = {let policies: array(Pulumi.Output.t(arn));};
module NoPolicies: Policies = {
  let policies = [|
    Pulumi.Output.make(PulumiAws.Lambda.Policy.awsLambdaFullAccess),
    Pulumi.Output.make(PulumiAws.SQS.QueuePolicy.amazonSQSFullAccess),
  |];
};

module type T = {
  let make:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~eventHandler: eventHandler,
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    t;
};

type connector = {resource: Adapter.resource};
type connectorMaker =
  (
    ~name: string,
    ~eventServices: array(string),
    ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
    ~policies: array(Pulumi.Output.t(arn)),
    ~handleEvents: (. array(Js.Json.t)) => Js.Promise.t(unit),
    ~memorySize: int,
    ~timeout: int,
    ~opts: Pulumi.CustomResourceOptions.t
  ) =>
  connector;

module type Connector = {let make: connectorMaker;};

module Make = (Policies: Policies, Connector: Connector) : T => {
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
  external makeOutputs: (~connector: Adapter.resource) => outputs = "";
  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct =
      (
        ~aggregateNames,
        ~eventHandler,
        ~queryEventTopic,
        ~memorySize,
        ~timeout,
        self,
        name,
      ) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let handleEvents =
      (. jsons) =>
        jsons
        |> Array.map(json => eventHandler(. json))
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());

    let connector =
      Connector.make(
        ~name=name->ComponentType.name(componentType),
        ~eventServices=aggregateNames,
        ~queryEventTopic,
        ~policies=Policies.policies,
        ~handleEvents,
        ~memorySize,
        ~timeout,
        ~opts,
      );

    makeOutputs(~connector=connector.resource) |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~eventHandler: (. Js.Json.t) => Js.Promise.t(unit),
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    t =
    (
      ~name,
      ~aggregateNames,
      ~eventHandler,
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
            ~eventHandler,
            ~queryEventTopic,
            ~memorySize,
            ~timeout,
          ),
        ~opts,
      );
};
