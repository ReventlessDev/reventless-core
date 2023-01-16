module ReventlessQueryDb = QueryDb;

let componentType = ComponentType.ReadModel;

type outputs = {
  .
  "name": string,
  "queryDb": QueryDb.outputs,
  "eventCollector": EventCollector.outputs,
};

type t;
type component = Component.t(t, outputs);

module type T = {
  module Spec: ReventlessSpec.ReadModelSpec.T;

  let make:
    (
      ~allEventTopics: EventTopic.allOutputs,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    component;
};

module Make =
       (
         Config: Config.T,
         Spec: ReventlessSpec.ReadModelSpec.T,
         Mappings:
           ReventlessSpec.Projection.Mappings with module Target := Spec,
         QueryDbStorage:
           QueryDb.Adapter.Storage with
             type api = Config.api and type role = Config.role,
         QueryDbResolvers:
           QueryDb.Adapter.Resolvers with
             type api = Config.api and type role = Config.role,
         EventCollectorConnector: EventCollector.Adapter.Connector,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  type constructed;
  type construct = (component, string) => constructed;

  [@module "./Component"] [@new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    component =
    "default";

  module QueryDb =
    QueryDb.Make(Config, Spec, QueryDbStorage, QueryDbResolvers);

  [@obj]
  external makeOutputs:
    (
      ~name: string,
      ~queryDb: ReventlessQueryDb.outputs,
      ~eventCollector: EventCollector.outputs
    ) =>
    outputs;
  [@send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct = (~allEventTopics, self, name) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let queryDb = QueryDb.make(~opts, ());

    let load: ReventlessSpec.QueryDb.load(string, Spec.state) =
      (. id) => queryDb->QueryDb.load(. id->Spec.Id.makeFromString);
    let save: ReventlessSpec.QueryDb.save(string, Spec.state) =
      (. id, state, saveMode, opt) =>
        queryDb->QueryDb.save(.
          id->Spec.Id.makeFromString,
          state,
          saveMode,
          opt,
        );
    let saveBatch: ReventlessSpec.QueryDb.saveBatch(string, Spec.state) =
      (. states) =>
        queryDb->QueryDb.saveBatch(.
          states->Belt.Array.map(((id, state, ttl)) =>
            (id->Spec.Id.makeFromString, state, ttl)
          ),
        );
    let delete: ReventlessSpec.QueryDb.delete(string) =
      (. id, sort) =>
        queryDb->QueryDb.delete(. id->Spec.Id.makeFromString, sort);

    let primitives = {ReventlessSpec.ReadModel.load, save, saveBatch, delete};

    module EventProjector = ProjectionMapper.Make(Spec, Mappings);

    let handleActions = (actions, primitives) =>
      actions
      ->Projection.handleActions(primitives)
      ->Js.Promise.all
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _); // TODO: error handling

    let eventsHandler =
      (. jsons) => {
        jsons
        ->Belt.Array.map(json => {
            let sourceName =
              json
              ->ReventlessSpec.Message.context_decode
              ->Belt.Result.map(context => context.meta.service)
              ->Belt.Result.getWithDefault("");
            json->EventProjector.map(~sourceName=Some(sourceName));
          })
        ->Belt.Array.concatMany
        ->handleActions(primitives);
      };

    module Set = Belt.Set.String;
    let aggregateNames =
      Mappings.mappings
      ->Belt.Array.map((module Mapping: Mappings.Mapping) =>
          Mapping.Source.name
        )
      ->Set.fromArray;

    module EventCollector = EventCollector.Make(EventCollectorConnector);
    let eventCollector =
      EventCollector.make(
        ~name=name->ComponentType.name(componentType),
        ~eventTopics=
          allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
        ~eventsHandler,
        ~opts=Some(opts),
        (),
      );

    // updateFn(
    //   projections,
    //   queryDb->QueryDb.load,
    //   queryDb->QueryDb.save,
    //   queryDb->QueryDb.delete,
    // )
    // |> self->setUpdate;

    makeOutputs(
      ~name,
      ~queryDb=queryDb->Component.extractOutputs,
      ~eventCollector=eventCollector->Component.extractOutputs,
    )
    |> self->setOutputs;
  };

  let make = (~allEventTopics, ~opts=?, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~allEventTopics),
      ~opts,
    );
  };
};
