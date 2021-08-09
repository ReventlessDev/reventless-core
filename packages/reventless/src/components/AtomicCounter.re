open ReventlessSpec.Adapter;

let componentType = ComponentType.AtomicCounter;

type increment =
  (. /*~name*/ string, /*~id*/ string, /*~ref*/ string) =>
  Js.Promise.t(Belt.Result.t(int, string));
type get =
  (. /*~name*/ string, /*~id*/ string) =>
  Js.Promise.t(Belt.Result.t(int, string));

type functions = {
  .
  "increment": increment,
  "get": get,
};

type outputs = {. "counter": resource};
external toOutputs: functions => outputs = "%identity";

type t = functions;

module type T = {
  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
};

module Adapter = {
  let counter = "Counter";
  type counter = {
    resource,
    increment,
    get,
  };

  module type Counter = {
    let make:
      (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => counter;
  };
};

module Make = (Counter: Adapter.Counter) : T => {
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

  [@bs.obj] external makeOutputs: (~counter: resource) => outputs = "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setIncrement: (t, increment) => unit = "increment";
  [@bs.set] external setGet: (t, get) => unit = "get";

  let construct = (self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let counter = Counter.make(~name, ~opts);

    self->setIncrement(counter.increment);
    self->setGet(counter.get);

    makeOutputs(~counter=counter.resource) |> self->setOutputs;
  };

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
    (~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=componentType->ComponentType.toName,
        ~construct,
        ~opts,
      );
    };
};
