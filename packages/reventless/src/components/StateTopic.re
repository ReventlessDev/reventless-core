open ReventlessSpec.Adapter;

let componentType = ComponentType.EventTopic;

type outputs = Js.t({.});

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  let name: string;

  [@decco]
  type state;
};

module type T = {
  module Spec: Spec;

  type t;

  let make:
    (
      ~name: string,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);
};

module Adapter = {
  type publisher = {resource};
  type publisherMaker =
    (
      ~name: string,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    publisher;

  module type Publisher = {let make: publisherMaker;};
};

module Make =
       (Spec: Spec, Publisher: Adapter.Publisher)
       : (T with module Spec = Spec) => {
  module Spec = Spec;
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

  [@bs.obj] external makeOutputs: (~publisher: resource) => outputs = "";

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

  let construct = (self, name, resources) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let publisher =
      Publisher.make(
        ~name=name->ComponentType.name(componentType),
        ~opts,
        ~resources,
      );
    resources->Util_EventTopic.setPublisherResource(publisher.resource, name);

    let publisherOutputs = publisher.resource;

    makeOutputs(~publisher=publisherOutputs) |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (~name, ~opts=?, ~resources, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct,
        ~opts,
        ~resources,
      );
    };
};
