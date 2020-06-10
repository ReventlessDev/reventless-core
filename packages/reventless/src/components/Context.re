let componentType = ComponentType.Context;

type serviceMakers = array(Service.maker);

type outputs = {
  .
  "name": string,
  "services": array(Service.t),
};
type t = outputs;

type maker = option(Pulumi.ComponentResource.Options.t) => t;

module type T = {
  let make:
    (
      ~name: string,
      ~serviceMakers: serviceMakers,
      option(Pulumi.ComponentResource.Options.t)
    ) =>
    t;
};

module Make = (Config: Config.T) : T => {
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
    (~name: string, ~services: array(Service.t)) => outputs =
    "";

  [@bs.send] external registerOutputs: (t, outputs) => constructed = "";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct = (~serviceMakers, self, name) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let services =
      serviceMakers |> Array.map(serviceMaker => serviceMaker(Some(opts)));

    makeOutputs(~name, ~services) |> self->setOutputs;
  };

  let make = (~name, ~serviceMakers, opts) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=name->ComponentType.name(componentType),
      ~construct=construct(~serviceMakers),
      ~opts,
    );
};