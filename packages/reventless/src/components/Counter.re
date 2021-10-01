open ReventlessSpec.Adapter;
open ReventlessSpec.Counter;

let componentType = ComponentType.Counter;
[@bs.inline]
let countFieldName = "count";

type outputs = {
  .
  "referencesDb": resource,
  "countsDb": resource,
};

type counterHandler =
  (~references: array(string), ~counts: array(Js.Json.t)) =>
  Js.Promise.t(unit);

type countItem = {
  counterId,
  reference,
};

type counterTarget = {
  counterId,
  target: int,
  targetRef: reference,
};

type action =
  | Count(countItem)
  | AddToCounterTarget(counterTarget);

type count = array(countItem) => Js.Promise.t(unit);
type addToCounterTarget = counterTarget => Js.Promise.t(unit);

exception NotCounted(string);

module Source = {
  module Id = Id.String;
  let name = componentType->ComponentType.toName;
  [@decco]
  type event =
    | CountFinished;
};

type counterEventsHandler = (. array(Js.Json.t)) => Js.Promise.t(unit);

module type T = {
  type t;

  let make:
    (
      ~name: string,
      ~counterEventsHandler: counterEventsHandler,
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let count: Component.t(t, outputs) => count;
  let addToCounterTarget: Component.t(t, outputs) => addToCounterTarget;
};

module Adapter = {
  type handler = {addToCounterTarget};
  type handlerMaker =
    (
      ~name: string,
      ~referencesName: string,
      ~countsName: string,
      ~counterHandler: counterHandler,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    handler;

  module type Handler = {let make: handlerMaker;};
};

module Make =
       (
         Config: Config.T,
         QueryDbStorage:
           QueryDb.Adapter.Storage with
             type api = Config.api and type role = Config.role,
         Handler: Adapter.Handler,
       )
       : T => {
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

  [@bs.obj]
  external makeOutputs:
    (~referencesDb: resource, ~countsDb: resource) => outputs =
    "";

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

  [@bs.set]
  external setCount: (Component.t(t, outputs), count) => unit = "count";
  [@bs.get] external count: Component.t(t, outputs) => count = "count";

  [@bs.set]
  external setAddToCounterTarget:
    (Component.t(t, outputs), addToCounterTarget) => unit =
    "addToCounterTarget";
  [@bs.get]
  external addToCounterTarget: Component.t(t, outputs) => addToCounterTarget =
    "addToCounterTarget";

  let construct =
      (
        ~counterEventsHandler: counterEventsHandler,
        ~ttl: option(int),
        self,
        name,
        resources,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );
    let opts2 =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    module AggregateSpec = {
      module Id = Id.String;
      let name = name;
    };

    module ReferencesViewSpec = {
      module Spec = AggregateSpec;
      let name = Some(name ++ "References");
      [@decco]
      type state = {id: Spec.Id.t};

      let resolveIdConfigs = [];
      let resolveIdsConfigs = [];
      let sortConfig = None;
      let indexes = [];
    };

    module ReferencesDb =
      QueryDb.Make(
        Config,
        AggregateSpec,
        ReferencesViewSpec,
        QueryDbStorage,
        (QueryDb.Adapter.NoResolvers(Config)),
      );

    module CountsViewSpec = {
      module Spec = AggregateSpec;
      let name = Some(name ++ "Counts");
      [@decco]
      type state = {
        id: string,
        count: int,
      }; //TODO: generalize

      let resolveIdConfigs = [];
      let resolveIdsConfigs = [];
      let sortConfig = None;
      let indexes = [];
    };

    module CountsDb =
      QueryDb.Make(
        Config,
        AggregateSpec,
        CountsViewSpec,
        QueryDbStorage,
        (QueryDb.Adapter.NoResolvers(Config)),
      );

    let separator = "#";
    let makeId = ((counterId, reference)) =>
      (counterId ++ separator ++ reference)->AggregateSpec.Id.makeFromString;
    let unmakeId = id =>
      id
      ->Js.String2.split(separator)
      ->(
          fun
          | [||] => ("", "")
          | [|counterId|] => (counterId, "")
          | parts => (parts[0], parts[1])
        );

    let groupCountItemsByCounterId = countItems => {
      let dict = Js.Dict.empty();
      countItems->Belt.Array.forEach(({counterId, reference}) => {
        let currentReferences =
          dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault([||]);
        dict->Js.Dict.set(
          counterId,
          currentReferences->Belt.Array.concat([|reference|]),
        );
      });
      dict->Js.Dict.entries;
    };

    let logCountItems = countItems =>
      countItems
      ->groupCountItemsByCounterId
      ->Belt.Array.forEach(((counterId, references)) => {
          let size = references->Belt.Array.size;
          let referencesStr = references->Js.Array2.joinWith(",");
          Js.log(
            {j|  $size references for counterId $counterId: $referencesStr|j},
          );
        });

    let count = (saveBatch, countItems) =>
      saveBatch(.
        countItems->Belt.Array.map(({counterId, reference}) => {
          let id = makeId((counterId, reference));
          let state: ReferencesViewSpec.state = {id: id};
          (id, state, ttl);
        }),
      )
      ->Js.Promise.then_(
          fun
          | Belt.Result.Ok(_) => {
              let batchSize = countItems->Belt.Array.size;
              Js.log(
                __MODULE__ ++ {j|: saved batch of $batchSize references:|j},
              );
              countItems->logCountItems;
              Js.Promise.resolve();
            }
          | Error(Reventless.QueryDb.NotSavedToStorage(err)) => {
              let batchSize = countItems->Belt.Array.size;
              Js.log(
                {j|Counter error: couldn't save batch of $batchSize references:|j},
              );
              countItems->logCountItems;
              NotCounted(err)->Js.Promise.reject;
            }
          | Error(_) => {
              let batchSize = countItems->Belt.Array.size;
              Js.log(
                {j|Unknown Counter error: couldn't save batch of $batchSize references:|j},
              );
              countItems->logCountItems;
              NotCounted("Unknown error")->Js.Promise.reject;
            },
          _,
        );

    let referencesDb = ReferencesDb.make(~ttl?, ~opts, ~resources, ());
    let countsDb = CountsDb.make(~ttl?, ~opts, ~resources, ());

    let referencesName =
      ReferencesViewSpec.name->Belt.Option.getWithDefault(AggregateSpec.name);
    let countsName =
      CountsViewSpec.name->Belt.Option.getWithDefault(AggregateSpec.name);

    let groupByCounterId = references => {
      let dict = Js.Dict.empty();
      references->Belt.Array.forEach(reference => {
        let counterId = reference->unmakeId->fst;
        let current =
          dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault(0);
        dict->Js.Dict.set(counterId, current + 1);
      });
      dict->Js.Dict.entries;
    };

    let counterHandler: counterHandler =
      (~references, ~counts) => {
        let countP =
          references
          ->groupByCounterId
          ->Belt.Array.map(((counterId, dec)) =>
              countsDb->CountsDb.count(.
                counterId->AggregateSpec.Id.makeFromString,
                countFieldName,
                - dec,
              )
            )
          ->Js.Promise.all
          ->Js.Promise.then_(_ => Js.Promise.resolve(), _); // TODO error handling

        let counterEventsHandlerP =
          counterEventsHandler(.
            counts->Belt.Array.keepMap(state =>
              switch (state->CountsViewSpec.state_decode) {
              | Ok({id, count}) when count == 0 =>
                let (counterId, _) = id->unmakeId;
                Js.log(
                  __MODULE__ ++ {j|.counterHandler: finished $name($id)|j},
                );
                let meta = Message.generateMeta(~service=name, ());
                Some(
                  [|
                    ("id", counterId->Js.Json.string),
                    ("meta", meta->Message.meta_encode),
                    ("event", CountFinished->Source.event_encode),
                  |]
                  ->Js.Dict.fromArray
                  ->Js.Json.object_,
                );
              | Ok({id, count}) =>
                Js.log(
                  __MODULE__
                  ++ {j|.counterHandler: counted down $name($id) to $count|j},
                );
                None;
              | _ =>
                let stateStr = state->Js.Json.stringify;
                Js.log(
                  __MODULE__
                  ++ {j|.counterHandler: couldn't decode state $stateStr|j},
                );
                None;
              }
            ),
          );

        (countP, counterEventsHandlerP)
        ->Js.Promise.all2
        ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
      };

    let handler =
      Handler.make(
        ~name,
        ~referencesName,
        ~countsName,
        ~counterHandler,
        ~opts=opts2,
        ~resources,
      );

    self->setCount(count(referencesDb->ReferencesDb.saveBatch));
    self->setAddToCounterTarget(handler.addToCounterTarget);

    makeOutputs(
      ~referencesDb=referencesDb->ReferencesDb.outputs##storage,
      ~countsDb=countsDb->CountsDb.outputs##storage,
    )
    |> self->setOutputs;
  };

  let oneWeek = 60 * 60 * 24 * 7; //604800 sec

  let make:
    (
      ~name: string,
      ~counterEventsHandler: counterEventsHandler,
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (~name, ~counterEventsHandler, ~ttl=oneWeek, ~opts=?, ~resources, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=name->ComponentType.name(componentType),
        ~construct=construct(~counterEventsHandler, ~ttl=Some(ttl)),
        ~opts,
        ~resources,
      );
    };
};
