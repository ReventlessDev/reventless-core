open ReventlessSpec.Adapter;
open ReventlessSpec.Counter;

let componentType = ComponentType.Counter;

type outputs = {
  .
  "referencesDb": resource,
  "countsDb": resource,
};

type eventsHandler = (. array(Js.Json.t)) => Js.Promise.t(unit);

type action =
  | Count(countItem)
  | SetCounterTarget(counterTarget);

type count = array(countItem) => Js.Promise.t(unit);
type setCounterTarget = counterTarget => Js.Promise.t(unit);

exception NotCounted(string);

module Source: ReventlessSpec.EventMapping.Source = {
  module Id = Id.String;
  let name = componentType->ComponentType.toName;
  [@decco]
  type event =
    | CountFinished;
};

type counterEventsHandler = (. array(Js.Json.t)) => Js.Promise.t(unit);

module type T = {
  type t;
  module Target: ReventlessSpec.EventMapping.Target;

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
  let setCounterTarget: Component.t(t, outputs) => setCounterTarget;
};

module Adapter = {
  type handler = unit;
  type handlerMaker =
    (
      ~name: string,
      ~readModelNames: array(string),
      ~handleEvents: eventsHandler,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    handler;

  module type Handler = {let make: handlerMaker;};
};

module Make =
       (
         Config: Config.T,
         Target: ReventlessSpec.EventMapping.Target,
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

  module Target = Target;

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
  external setSetCounterTarget:
    (Component.t(t, outputs), setCounterTarget) => unit =
    "setCounterTarget";
  [@bs.get]
  external setCounterTarget: Component.t(t, outputs) => setCounterTarget =
    "setCounterTarget";

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

    module AggregateSpec = {
      module Id = Id.String;
      let name = name;
    };

    module ReferencesViewSpec = {
      module Spec = AggregateSpec;
      let name = Some(name ++ "References");
      [@decco]
      type state = unit;

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

    let countFieldName = "count";

    module CountsViewSpec = {
      module Spec = AggregateSpec;
      let name = Some(name ++ "Counts");
      [@decco]
      type state = {count: int}; //TODO: generalize

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

    let countFn = (saveBatch, countItems) =>
      saveBatch(.
        countItems->Belt.Array.map(({counterId, item}) =>
          (
            (counterId ++ "#" ++ item)->AggregateSpec.Id.makeFromString,
            (),
            ttl,
          )
        ),
      )
      |> Js.Promise.then_(
           fun
           | Belt.Result.Ok(_) => Js.Promise.resolve()
           | Error(Reventless.QueryDb.NotSavedToStorage(err)) =>
             NotCounted(err)->Js.Promise.reject
           | Error(_) => NotCounted("Unknown error")->Js.Promise.reject,
         );

    let setCounterTargetFn = (count, {counterId, target}) =>
      count(. counterId->Id.String.makeFromString, countFieldName, target)
      |> Js.Promise.then_(
           fun
           | Belt.Result.Ok(_) => Js.Promise.resolve()
           | Error(Reventless.QueryDb.NotSavedToStorage(err)) =>
             NotCounted(err)->Js.Promise.reject
           | Error(_) => NotCounted("Unknown error")->Js.Promise.reject,
         );

    let referencesDb = ReferencesDb.make(~ttl?, ~opts, ~resources, ());
    let countsDb = CountsDb.make(~ttl?, ~opts, ~resources, ());

    self->setCount(referencesDb->ReferencesDb.saveBatch->countFn);
    self->setSetCounterTarget(countsDb->CountsDb.count->setCounterTargetFn);

    let counterLambdaHandler = {
      /* TODO:
       *  - read AWS event and calculate Counter-Event
       *  - pass Js.Json.t of Counter-Event to counerHandler (argument to make())
       */
      // foreach record in stream, create event':
      let id = "TODO";
      let event = "TODO";
      let event' = Js.Json.string("TODO");
      counterEventsHandler(. [|event'|]);
    };

    // let handler = Handler.make();

    // let handleStreamEvent = (handleEvents, streamEvent, _) => {
    //   let records = streamEvent##_Records->Belt.Option.getWithDefault([||]);
    //   let jsons =
    //     records->Belt.Array.keepMap(record =>
    //       switch (record##eventSource) {
    //       | "aws:dynamodb" =>
    //         record->Util_DynamoDbStream_Runtime.parseDynamoDbStreamRecord
    //       | eventSource =>
    //         Js.log2(
    //           "EventCollectorConnector_DynamoDbStream_Runtime: ignoring record from eventSource:",
    //           eventSource,
    //         );
    //         None;
    //       }
    //     );
    //   handleEvents(. jsons)
    //   |> Js.Promise.catch(err =>
    //        Js.Exn.raiseError(err->AwsSdk.Error.ofPromise##message)
    //      );
    // };

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
