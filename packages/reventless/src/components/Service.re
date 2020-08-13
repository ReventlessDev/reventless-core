let componentType = ComponentType.Service;

type outputs = {
  .
  "name": string,
  "aggregate": Aggregate.t,
  "readModel": ReadModel.outputs,
};
type t = outputs;

type maker = option(Pulumi.ComponentResource.Options.t) => t;

module type Spec = {
  module Id: Id.T;

  let name: string;

  [@decco]
  type command;
  [@decco]
  type event;
  [@decco]
  type error;
};
module type T = {let make: maker;};

module Make =
       (
         Spec: Spec,
         Aggregate: Aggregate.T with module Spec := Spec,
         ReadModel: ReadModel.T with module Spec := Spec,
       )
       : T => {
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
      ~name: string,
      ~aggregate: Reventless.Aggregate.t,
      ~readModel: Reventless.ReadModel.t(Spec.Id.t, Spec.event)
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

  let construct = (self, _name) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let readModel = ReadModel.make(Some(opts));

    let aggregate =
      Aggregate.make(~eventsHandler=readModel##update, ~opts, ());

    makeOutputs(~name=Spec.name, ~aggregate, ~readModel) |> self->setOutputs;
  };

  let make = opts =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name->ComponentType.name(componentType),
      ~construct,
      ~opts,
    );
};
