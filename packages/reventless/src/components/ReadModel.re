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

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    component =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~name: string,
      ~queryDb: QueryDb.outputs,
      ~eventCollector: EventCollector.outputs
    ) =>
    outputs =
    "";
  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
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

    module QueryDb =
      QueryDb.Make(Config, Spec, QueryDbStorage, QueryDbResolvers);

    let queryDb = QueryDb.make(~opts, ());

    let load = (. id) => queryDb->QueryDb.load(. id->Spec.Id.makeFromString);
    let save =
      (. id, state, saveMode, opt) =>
        queryDb->QueryDb.save(.
          id->Spec.Id.makeFromString,
          state,
          saveMode,
          opt,
        );
    let saveBatch =
      (. states) =>
        queryDb->QueryDb.saveBatch(.
          states->Belt.Array.map(((id, state, ttl)) =>
            (id->Spec.Id.makeFromString, state, ttl)
          ),
        );
    let delete =
      (. id, sort) =>
        queryDb->QueryDb.delete(. id->Spec.Id.makeFromString, sort);

    let primitives = {Projection.load, save, saveBatch, delete};

    module EventProjector = ProjectionMapper.Make(Spec, Mappings);

    let handleActions = (actions, primitives, subIdConfig) =>
      actions
      ->Projection.handleActions(primitives, subIdConfig)
      ->Js.Promise.all
      ->Js.Promise.then_(
          results => {
            let errors =
              results->Belt.Array.keepMap(
                fun
                | Belt.Result.Error(err) => Some(err)
                | _ => None,
              );
            switch (errors) {
            | [||] => Js.Promise.resolve()
            | errors =>
              let count = errors->Belt.Array.size;
              Js.Exn.raiseError(
                {j|ReadModel.handleActions failed with $count errors: $errors|j},
              );
            };
          },
          _,
        );

    let eventsHandler: (. array(Js.Json.t)) => Js.Promise.t(unit) =
      (. jsons) => {
        let eventCount = jsons->Belt.Array.length;
        jsons
        ->Belt.Array.mapWithIndex((idx, json) => {
            let idx = idx + 1;
            let sourceName =
              json
              ->ReventlessSpec.Message.context_decode
              ->Belt.Result.map(context => context.meta.service)
              ->Belt.Result.getWithDefault("");
            Js.log2(
              {j|ReadModel: handling event $idx/$eventCount from $sourceName:|j},
              json,
            );
            json->EventProjector.map(~sourceName=Some(sourceName));
          })
        ->Belt.Array.concatMany
        ->handleActions(primitives, Spec.subIdConfig);
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
