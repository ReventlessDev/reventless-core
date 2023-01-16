open ReventlessSpec.Adapter;

let componentType = ComponentType.EventTopic;

type outputs = Js.t({.});

type t;
type component = Component.t(t, outputs);

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  let name: string;

  [@decco]
  type state;
};

module type T = {
  module Spec: Spec;

  let make:
    (
      ~name: string,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~allQueryDbs: QueryDb.allOutputs,
      unit
    ) =>
    component;
};

module Adapter = {
  type publisher = {resource};
  type publisherMaker =
    (
      ~name: string,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~allQueryDbs: QueryDb.allOutputs
    ) =>
    publisher;

  module type Publisher = {let make: publisherMaker;};
};

module Make =
       (Spec: Spec, Publisher: Adapter.Publisher)
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  type constructed;
  type construct = (component, string, QueryDb.allOutputs) => constructed;

  [@module "./Component"] [@new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~allQueryDbs: QueryDb.allOutputs
    ) =>
    component =
    "default";

  [@obj] external makeOutputs: (~publisher: resource) => outputs;

  [@send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct = (self, name, allQueryDbs) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let publisher =
      Publisher.make(
        ~name=name->ComponentType.name(componentType),
        ~opts,
        ~allQueryDbs,
      );

    let publisherOutputs = publisher.resource;

    makeOutputs(~publisher=publisherOutputs) |> self->setOutputs;
  };

  let make = (~name, ~opts=?, ~allQueryDbs, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
      ~allQueryDbs,
    );
  };
};
