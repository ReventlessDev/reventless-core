let componentType = ComponentType.Service;

type outputs = {
  .
  "name": string,
  "aggregate": Aggregate.t,
  "readModel": ReadModel.outputs,
};
type t = outputs;

type maker = option(Pulumi.ComponentResource.Options.t) => t;

module type T = {let make: maker;};

module Make =
       (
         Service: Message.Service,
         Aggregate:
           Aggregate.T with
             type id = Service.id and type event = Service.event,
         ReadModel:
           ReadModel.T with
             type id = Service.id and type event = Service.event,
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
      ~readModel: Reventless.ReadModel.t(Service.id, Service.event)
    ) =>
    outputs =
    "";

  [@bs.send] external registerOutputs: (t, outputs) => constructed = "";
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

    makeOutputs(~name=Service.name, ~aggregate, ~readModel)
    |> self->setOutputs;
  };

  let make = opts =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Service.name->ComponentType.name(componentType),
      ~construct,
      ~opts,
    );
};