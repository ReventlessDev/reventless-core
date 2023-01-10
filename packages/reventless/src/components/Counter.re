open ReventlessSpec.Adapter;
open ReventlessSpec.Counter;

let componentType = ComponentType.Counter;
[@bs.inline]
let countFieldName = "count";

type outputs = {
  .
  "resources": array(resource), // TODO: only use resources - remove everything else in the outputs
  "referencesDb": array(resource),
  "countsDb": array(resource),
};

type t;
type component = Component.t(t, outputs);

type counterHandler =
  (~references: array((string, int)), ~counts: array(Js.Json.t)) =>
  Js.Promise.t(unit);

type countItem = {
  counterId,
  reference,
  inc: int,
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
  let make:
    (
      ~name: string,
      ~counterEventsHandler: counterEventsHandler,
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    component;

  let count: component => count;
  let addToCounterTarget: component => addToCounterTarget;
};

module Adapter = {
  type handler = {
    resources: array(resource),
    addToCounterTarget,
  };
  type handlerMaker =
    (
      ~name: string,
      ~referencesName: string,
      ~referencesDb: QueryDb.outputs,
      ~countsName: string,
      ~countsDb: QueryDb.outputs,
      ~counterHandler: counterHandler,
      ~opts: Pulumi.CustomResourceOptions.t
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
      ~resources: array(resource),
      ~referencesDb: array(resource),
      ~countsDb: array(resource)
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

  [@bs.set] external setCount: (component, count) => unit = "count";
  [@bs.get] external count: component => count = "count";

  [@bs.set]
  external setAddToCounterTarget: (component, addToCounterTarget) => unit =
    "addToCounterTarget";
  [@bs.get]
  external addToCounterTarget: component => addToCounterTarget =
    "addToCounterTarget";

  let construct =
      (
        ~counterEventsHandler: counterEventsHandler,
        ~ttl: option(int),
        self,
        name,
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
      module Id = Id.StringPure;
      let name = name;
    };

    module ReferencesViewSpec = {
      module Spec = AggregateSpec;
      let name = Some(name ++ "References");
      [@decco]
      type state = {
        id: string,
        inc: int,
      };

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
      counterId ++ separator ++ reference;
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
            {j|  $size reference(s) for counterId $counterId: $referencesStr|j},
          );
        });

    let count = (saveBatch, countItems) =>
      saveBatch(.
        countItems->Belt.Array.map(({counterId, reference, inc}) => {
          let id = makeId((counterId, reference));
          let state: ReferencesViewSpec.state = {id, inc};
          (id, state, ttl);
        }),
      )
      ->Js.Promise.then_(
          fun
          | Belt.Result.Ok(_) => {
              let batchSize = countItems->Belt.Array.size;
              Js.log(
                __MODULE__ ++ {j|: saved batch of $batchSize reference(s):|j},
              );
              countItems->logCountItems;
              Js.Promise.resolve();
            }
          | Error(QueryDb.NotSavedToStorage(err)) => {
              let batchSize = countItems->Belt.Array.size;
              Js.log(
                {j|Counter error: couldn't save batch of $batchSize reference(s):|j},
              );
              countItems->logCountItems;
              NotCounted(err)->Js.Promise.reject;
            }
          | Error(_) => {
              let batchSize = countItems->Belt.Array.size;
              Js.log(
                {j|Unknown Counter error: couldn't save batch of $batchSize reference(s):|j},
              );
              countItems->logCountItems;
              NotCounted("Unknown error")->Js.Promise.reject;
            },
          _,
        );

    let referencesDb = ReferencesDb.make(~ttl?, ~opts, ());
    let countsDb = CountsDb.make(~ttl?, ~opts, ());

    let referencesName =
      ReferencesViewSpec.name->Belt.Option.getWithDefault(AggregateSpec.name);
    let countsName =
      CountsViewSpec.name->Belt.Option.getWithDefault(AggregateSpec.name);

    let groupByCounterId = references => {
      let dict = Js.Dict.empty();
      references->Belt.Array.forEach(((reference, inc)) => {
        let counterId = reference->unmakeId->fst;
        let current =
          dict->Js.Dict.get(counterId)->Belt.Option.getWithDefault(0);
        dict->Js.Dict.set(counterId, current + inc);
      });
      dict->Js.Dict.entries;
    };

    let counterHandler: counterHandler =
      (~references, ~counts) => {
        Js.log2("counterHandler: references:", references->Belt.Array.size);
        Js.log2("counterHandler: counts:", counts);
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
                  __MODULE__
                  ++ {j|.counterHandler: counted down $name($id) to $count|j},
                );
                let meta =
                  Message.generateMeta(
                    ~service=Source.name,
                    ~user="Counter",
                    (),
                  );
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
        ~referencesDb=referencesDb->Component.extractOutputs,
        ~countsName,
        ~countsDb=countsDb->Component.extractOutputs,
        ~counterHandler,
        ~opts=opts2,
      );

    self->setCount(count(referencesDb->ReferencesDb.saveBatch));
    self->setAddToCounterTarget(handler.addToCounterTarget);

    let referencesDbResources = referencesDb->ReferencesDb.outputs##resources;
    let countsDbResources = countsDb->CountsDb.outputs##resources;

    makeOutputs(
      ~resources=
        Belt.Array.concatMany([|
          referencesDbResources,
          countsDbResources,
          handler.resources,
        |]),
      ~referencesDb=referencesDbResources,
      ~countsDb=countsDbResources,
    )
    |> self->setOutputs;
  };

  let oneWeek = 60 * 60 * 24 * 7; //604800 sec

  let make = (~name, ~counterEventsHandler, ~ttl=oneWeek, ~opts=?, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=name->ComponentType.name(componentType),
      ~construct=construct(~counterEventsHandler, ~ttl=Some(ttl)),
      ~opts,
    );
  };
};
