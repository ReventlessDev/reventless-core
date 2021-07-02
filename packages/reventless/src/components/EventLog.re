open ReventlessSpec.Adapter;

let componentType = ComponentType.EventLog;

type outputs = {. "storage": resource};

exception ReplayError(string);

type append('id, 'event) =
  (. int, 'id, array('event)) => Js.Promise.t(unit);
type replay('id, 'event) = (. 'id) => Js.Promise.t(array('event));

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  let name: string;

  [@decco]
  type event;
};

module type T = {
  module Spec: Spec;
  type t;

  let make:
    (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) =>
    Component.t(t, outputs);

  let append:
    Component.t(t, outputs) =>
    append(Spec.Id.t, Message.event'(Spec.Id.t, Spec.event));
  let replay: Component.t(t, outputs) => replay(Spec.Id.t, Spec.event);
};

type storage = {
  resource,
  append: append(string, Js.Json.t),
  replay: replay(string, Js.Json.t),
};
type storageMaker =
  (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage;

module type Storage = {let make: storageMaker;};

module Make = (Spec: Spec, Storage: Storage) : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type constructed;
  type construct = (Component.t(t, outputs), string) => constructed;

  type nonrec append =
    append(Spec.Id.t, Message.event'(Spec.Id.t, Spec.event));
  type nonrec replay = replay(Spec.Id.t, Spec.event);

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj] external makeOutputs: (~storage: resource) => outputs = "";

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
  external setAppend: (Component.t(t, outputs), append) => unit = "append";
  [@bs.set]
  external setReplay: (Component.t(t, outputs), replay) => unit = "replay";
  [@bs.get] external append: Component.t(t, outputs) => append = "append";
  [@bs.get] external replay: Component.t(t, outputs) => replay = "replay";

  let appendFn = storage =>
    (. sequenceNr, id, events') =>
      try (
        events'->Belt.Array.map(
          (event': Message.event'(Spec.Id.t, Spec.event)) =>
          [|
            ("id", Spec.Id.t_encode(id)),
            (
              "sequenceNr",
              Js.Json.string(
                Message.hrtimeToString(
                  ~hrtime=Message.hrtime(),
                  ~now=Message.now(),
                ),
              ),
            ),
            ("event", event'.event |> Spec.event_encode),
          |]
          ->Belt.Array.concat(
              event'.meta
              ->Message.meta_encode
              ->Js.Json.decodeObject
              ->Js.Option.getExn
              ->Js.Dict.entries,
            )
          ->Js.Dict.fromArray
          ->Js.Json.object_
        )
        |> (
          data =>
            storage.append(. sequenceNr, id |> Spec.Id.toString, data)
            |> Js.Promise.catch(err => {
                 let serviceName = Spec.name;
                 let resourceName = storage.resource##name->Pulumi.Output.get;
                 Js.Promise.resolve(
                   Js.log(
                     {j|EventLog: Error: Couldn't append for $serviceName($id) on $resourceName: $err|j},
                   ),
                 );
               })
        )
      ) {
      | exn =>
        Js.log2("EventLog.append: Couldn't decode:", exn);
        raise(exn);
      };

  let replayFn = storage =>
    (. id) => {
      storage.replay(. id |> Spec.Id.toString)
      |> Js.Promise.then_(jsons =>
           jsons->Belt.Array.map(json =>
             Js.Json.decodeObject(json)
             ->Belt.Option.flatMap(dict => dict->Js.Dict.get("event"))
             ->Belt.Option.map(json => (json, Spec.event_decode(json)))
             ->Belt.Option.map(
                 fun
                 | (_, Belt.Result.Ok(event)) => event
                 | (json, Error(err)) => {
                     let eventStr = json |> Js.Json.stringify;
                     let message = err.message;
                     Js.Exn.raiseError(
                       {j|EventLog.replay: Error: Couldn't decode $eventStr: $message|j},
                     );
                   },
               )
             ->(
                 fun
                 | Some(event) => event
                 | None => {
                     let eventStr = json |> Js.Json.stringify;
                     Js.Exn.raiseError(
                       {j|EventLog.replay: Error: Couldn't decodeObject $eventStr|j},
                     );
                   }
               )
           )
           |> Js.Promise.resolve
         );
    };

  let construct = (self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let storage =
      Storage.make(~name=name->ComponentType.name(componentType), ~opts);
    let storageOutputs = storage.resource;

    self->setAppend(storage->appendFn);
    self->setReplay(storage->replayFn);

    makeOutputs(~storage=storageOutputs) |> self->setOutputs;
  };

  let make:
    (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) =>
    Component.t(t, outputs) =
    (~name, ~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct,
        ~opts,
      );
    };
};
