open ReventlessSpec.Adapter;

let componentType = ComponentType.AtomicCounter;

type outputs = {
  .
  "referencesDb": resource,
  "counterDb": resource,
};

type countItem = {
  counter: string,
  id: string,
  item: string,
};

type counterTarget = {
  counter: string,
  id: string,
  target: int,
};

type count = array(countItem) => Js.Promise.t(unit);
type setCounterTarget = counterTarget => Js.Promise.t(unit);

module type Handler = {let onFinished: string => Js.Promise.t(unit);};

exception NotCounted(string);

module type T = {
  type t;
  let make:
    (
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let count: Component.t(t, outputs) => count;
  let setCounterTarget: Component.t(t, outputs) => setCounterTarget;
};

module Make =
       (
         Config: Config.T,
         Handler: Handler,
         QueryDbStorage:
           QueryDb.Adapter.Storage with
             type api = Config.api and type role = Config.role,
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
    (~referencesDb: resource, ~counterDb: resource) => outputs =
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

  let construct = (~ttl: option(int), self, name, resources) => {
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

    module CounterViewSpec = {
      module Spec = AggregateSpec;
      let name = Some(name ++ "Counter");
      [@decco]
      type state = {count: int}; //TODO: generalize

      let resolveIdConfigs = [];
      let resolveIdsConfigs = [];
      let sortConfig = None;
      let indexes = [];
    };

    module CounterDb =
      QueryDb.Make(
        Config,
        AggregateSpec,
        CounterViewSpec,
        QueryDbStorage,
        (QueryDb.Adapter.NoResolvers(Config)),
      );

    let countFn = (saveBatch, countItems) =>
      saveBatch(.
        countItems->Belt.Array.map(({counter, id, item}) =>
          (
            (counter ++ "-" ++ id ++ "#" ++ item)
            ->AggregateSpec.Id.makeFromString,
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

    let setCounterTargetFn = (count, {counter, id, target}) =>
      count(. id->Id.String.makeFromString, counter, target)
      |> Js.Promise.then_(
           fun
           | Belt.Result.Ok(_) => Js.Promise.resolve()
           | Error(Reventless.QueryDb.NotSavedToStorage(err)) =>
             NotCounted(err)->Js.Promise.reject
           | Error(_) => NotCounted("Unknown error")->Js.Promise.reject,
         );

    let referencesDb = ReferencesDb.make(~ttl?, ~opts, ~resources, ());
    let counterDb = CounterDb.make(~ttl?, ~opts, ~resources, ());

    self->setCount(referencesDb->ReferencesDb.saveBatch->countFn);
    self->setSetCounterTarget(counterDb->CounterDb.count->setCounterTargetFn);

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
    // let eventHandlerLambda =
    //   PulumiAws.Lambda.CallbackFunction.make(
    //     ~name,
    //     ~args=
    //       PulumiAws.Lambda.CallbackFunction.Args.make(
    //         ~callback=
    //           EventCollectorConnector_SQS_Runtime.handleCallbackEvent(
    //             handleEvents,
    //             queue,
    //           ),
    //         (),
    //       ),
    //     ~opts,
    //     (),
    //   );

    makeOutputs(
      ~referencesDb=referencesDb->ReferencesDb.outputs##storage,
      ~counterDb=counterDb->CounterDb.outputs##storage,
    )
    |> self->setOutputs;
  };

  let oneWeek = 60 * 60 * 24 * 7; //604800 sec

  let make:
    (
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (~ttl=oneWeek, ~opts=?, ~resources, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=componentType->ComponentType.toName,
        ~construct=construct(~ttl=Some(ttl)),
        ~opts,
        ~resources,
      );
    };
};
