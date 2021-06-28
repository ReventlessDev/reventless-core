let componentType = ComponentType.Service;

type outputs = {
  .
  "name": string,
  "aggregate": Aggregate.outputs,
  "readModel": ReadModel.outputs,
};

type service; // TODO: rename this back to t after refactor
type maker =
  option(Pulumi.ComponentResource.Options.t) => Component.t(service, outputs);

module type T = {let make: maker;};

module Make =
       (
         Config: Config.T,
         Spec: ReventlessSpec.AggregateSpec.T,
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
  type construct = (Component.t(service, outputs), string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(service, outputs) =
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
    (
      ~name: string,
      ~aggregate: Reventless.Aggregate.outputs,
      ~readModel: Reventless.ReadModel.outputs
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs:
    (Component.t(service, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(service, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct: construct =
    (self, _name) => {
      let opts =
        Pulumi.ComponentResource.Options.make(
          ~parent=self->Component.toPulumiResource,
          (),
        );

      let readModel = ReadModel.make(Some(opts));

      let aggregate =
        Aggregate.make(~eventsHandler=readModel->ReadModel.update, ~opts, ());

      makeOutputs(
        ~name=Spec.name,
        ~aggregate=aggregate->Component.extractOutputs,
        ~readModel=readModel->Component.extractOutputs,
      )
      ->setOutputs(self, _);
    };

  let make = opts =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct,
      ~opts,
    );
};
