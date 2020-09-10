let componentType = ComponentType.EventLog;

exception ReplayError(string);

type append('id, 'event) =
  (. int, 'id, array('event)) => Js.Promise.t(unit);
type replay('id, 'event) = (. 'id) => Js.Promise.t(array('event));

type functions('id, 'event) = {
  .
  "append": append('id, Message.event'('id, 'event)),
  "replay": replay('id, 'event),
};

type outputs = {. "storage": Adapter.resource};
external toOutputs: functions('id, 'command) => outputs = "%identity";

type t('id, 'command) = functions('id, 'command);

module type Spec = {
  module Id: Id.T;

  let name: string;

  [@decco]
  type event;
};

module type T = {
  module Spec: Spec;
  type nonrec t = t(Spec.Id.t, Spec.event);

  let make:
    (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
};

type storage = {
  resource: Adapter.resource,
  append: append(string, Js.Json.t),
  replay: replay(string, Js.Json.t),
};
type storageMaker =
  (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage;

module type Storage = {let make: storageMaker;};

module Make = (Spec: Spec, Storage: Storage) : (T with module Spec = Spec) => {
  module Spec = Spec;
  type nonrec t = t(Spec.Id.t, Spec.event);

  type constructed;
  type construct = (t, string) => constructed;

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
    t =
    "default";

  [@bs.obj] external makeOutputs: (~storage: Adapter.resource) => outputs = "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setAppend: (t, append) => unit = "append";
  [@bs.set] external setReplay: (t, replay) => unit = "replay";

  let append = storage =>
    (. sequenceNr, id, events') =>
      try (
        events'
        |> Array.map((event': Message.event'(Spec.Id.t, Spec.event)) =>
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
             |> Array.append(
                  event'.meta
                  |> Message.meta_encode
                  |> Js.Json.decodeObject
                  |> Js.Option.getExn
                  |> Js.Dict.entries,
                )
             |> Js.Dict.fromArray
             |> Js.Json.object_
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

  let replay = storage =>
    (. id) => {
      storage.replay(. id |> Spec.Id.toString)
      |> Js.Promise.then_(jsons =>
           jsons
           |> Array.map(json =>
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
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let storage =
      Storage.make(~name=name->ComponentType.name(componentType), ~opts);
    let storageOutputs = storage.resource;

    self->setAppend(storage->append);
    self->setReplay(storage->replay);

    makeOutputs(~storage=storageOutputs) |> self->setOutputs;
  };

  let make:
    (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
    (~name, ~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct,
        ~opts,
      );
    };
};
