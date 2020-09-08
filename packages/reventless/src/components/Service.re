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
         Config: Config.T,
         Spec: Aggregate.Spec,
         Behaviour: Behaviour.T with module Spec := Spec,
         View: View.T with module Spec := Spec,
         CommandGeneratorResolvers:
           CommandGenerator.Resolvers with type api := Config.api,
         CommandTopicConnector: CommandTopic.Connector,
         EventLogStorage: EventLog.Storage,
         EventTopicPublisher: EventTopic.Publisher,
         QueryDbStorage:
           QueryDb.Storage with
             type api = Config.api and type role = Config.role,
         QueryDbResolvers:
           QueryDb.Resolvers with
             type api = Config.api and type role = Config.role,
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

  module Aggregate =
    Aggregate.Make(
      Config,
      Spec,
      Behaviour,
      CommandGeneratorResolvers,
      CommandTopicConnector,
      EventLogStorage,
      EventTopicPublisher,
    );
  module ReadModel =
    ReadModel.Make(Config, Spec, View, QueryDbStorage, QueryDbResolvers);

  [@bs.obj]
  external makeOutputs:
    (~name: string, ~aggregate: Aggregate.t, ~readModel: ReadModel.t) =>
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
      ~name=Spec.name,
      ~construct,
      ~opts,
    );
};
