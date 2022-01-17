open ReventlessSpec.Adapter;

let componentType = ComponentType.EventLog;

type outputs = {
  .
  "resources": array(resource),
  "eventTopic": EventTopic.outputs,
};

exception ReplayError(string);

type append('id, 'event) =
  (. int, 'id, array('event)) => Js.Promise.t(Belt.Result.t(unit, string));
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
    (
      ~name: string,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let append:
    Component.t(t, outputs) =>
    append(Spec.Id.t, Message.event'(Spec.Id.t, Spec.event));
  let replay: Component.t(t, outputs) => replay(Spec.Id.t, Spec.event);
};

module Adapter = {
  type storage = {
    resources: array(resource),
    append: append(string, Js.Json.t),
    replay: replay(string, Js.Json.t),
  };
  type storageMaker =
    (
      ~name: string,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    storage;

  module type Storage = {let make: storageMaker;};
};

module Make =
       (
         Spec: Spec,
         Storage: Adapter.Storage,
         EventTopicPublisher: EventTopic.Adapter.Publisher,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type constructed;
  type construct =
    (Component.t(t, outputs), string, resources) => constructed;

  type nonrec append =
    append(Spec.Id.t, Message.event'(Spec.Id.t, Spec.event));
  type nonrec replay = replay(Spec.Id.t, Spec.event);

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
    (~resources: array(resource), ~eventTopic: EventTopic.outputs) => outputs =
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
  external setAppend: (Component.t(t, outputs), append) => unit = "append";
  [@bs.set]
  external setReplay: (Component.t(t, outputs), replay) => unit = "replay";
  [@bs.get] external append: Component.t(t, outputs) => append = "append";
  [@bs.get] external replay: Component.t(t, outputs) => replay = "replay";

  module EventTopic = EventTopic.Make(Spec, EventTopicPublisher);

  let appendFn = (storage, eventTopic) =>
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
          ->Belt.Array.concat(event'.meta->Message.decomposeMeta)
          ->Js.Dict.fromArray
          ->Js.Json.object_
        )
        |> (
          data =>
            storage.Adapter.append(. sequenceNr, id->Spec.Id.toString, data)
            |> Js.Promise.catch(err => {
                 let serviceName = Spec.name;
                 let resourceName =
                   storage.resources[0]##name->Pulumi.Output.get;
                 let err = {j|EventLog: Error: Couldn't append for $serviceName($id) on $resourceName: $err|j};
                 Js.log(err);
                 err->Belt.Result.Error->Js.Promise.resolve;
               })
            |> Js.Promise.then_(result => {
                 let _ =
                   eventTopic->EventTopic.publish(. events')
                   |> Js.Promise.catch(err => {
                        let msg =
                          {j|EventLog.appendFn($id): EventTopic.publish Error: |j}
                          ++
                          err->Util.Error.ofPromise##message;

                        Js.log(msg);
                        Js.Exn.raiseError(msg);
                      });

                 result->Js.Promise.resolve;
               })
        )
      ) {
      | exn =>
        Js.log2("EventLog.append: Couldn't decode:", exn);
        raise(exn);
      };

  let decodeEvent = json =>
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
      );

  let replayFn = storage =>
    (. id) => {
      storage.Adapter.replay(. id |> Spec.Id.toString)
      |> Js.Promise.then_(jsons =>
           jsons->Belt.Array.map(decodeEvent)->Js.Promise.resolve
         );
    };

  let construct = (self, name, resources) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let storage =
      Storage.make(
        ~name=name->ComponentType.name(componentType),
        ~opts,
        ~resources,
      );
    resources->Util_EventLog.setStorageResource(storage.resources[0], name);

    let eventTopic =
      EventTopic.make(
        ~name,
        ~opts=
          opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
        ~resources,
        (),
      );

    self->setAppend(storage->appendFn(eventTopic));
    self->setReplay(storage->replayFn);

    makeOutputs(
      ~resources=storage.resources,
      ~eventTopic=eventTopic->Component.extractOutputs,
    )
    |> self->setOutputs;
  };

  let make:
    (
      ~name: string,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (~name, ~opts=?, ~resources, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct,
        ~opts,
        ~resources,
      );
    };
};
