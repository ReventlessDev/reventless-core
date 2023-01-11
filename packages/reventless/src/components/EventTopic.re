open ReventlessSpec.Adapter;

let componentType = ComponentType.EventTopic;

type outputs = {. "resources": array(resource)};
type allOutputs = Js.Dict.t(outputs);

type t;
type component = Component.t(t, outputs);

type publish('id, 'event) =
  (. array(Message.event'('id, 'event))) => Js.Promise.t(unit);

exception NotPublishedToPublisher(Js.Promise.error);

module type Spec = {
  module Id: ReventlessSpec.Id.T;

  let name: string;

  [@decco]
  type event;
};

module type T = {
  module Spec: Spec;

  let make:
    (
      ~name: string,
      ~storageResources: array(resource),
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    component;

  let publish: component => publish(Spec.Id.t, Spec.event);
};

module Adapter = {
  type publisher = {
    resources: array(resource),
    publish: (. string, Message.meta, Js.Json.t) => Js.Promise.t(unit),
  };
  type publisherMaker =
    (
      ~name: string,
      ~storageResources: array(resource),
      ~opts: Pulumi.CustomResourceOptions.t
    ) =>
    publisher;

  module type Publisher = {let make: publisherMaker;};
};

module Make =
       (Spec: Spec, Publisher: Adapter.Publisher)
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  type constructed;
  type construct = (component, string) => constructed;

  type nonrec publish = publish(Spec.Id.t, Spec.event);

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
  external makeOutputs: (~resources: array(resource)) => outputs = "";

  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setPublish: (component, publish) => unit = "publish";
  [@bs.get] external publish: component => publish = "publish";

  let publishFn = (publisher: Adapter.publisher, name) =>
    (. events') => {
      let eventCount = events'->Belt.Array.length;
      events'->Belt.Array.mapWithIndex((idx, event') => {
        let json =
          Message.event'_encode(Spec.Id.t_encode, Spec.event_encode, event');

        let id = event'.id;
        let event = json->Js.Json.stringify;
        let eventName: string = event'.event->Spec.event_encode->Obj.magic[0];
        let idx = idx + 1;

        publisher.publish(. id->Spec.Id.toString, event'.meta, json)
        |> Js.Promise.catch(e => {
             Js.log(
               {j|EventTopic: Couldn't publish event $idx/$eventCount: $eventName($id) to $name|j},
             );
             NotPublishedToPublisher(e)->Js.Promise.reject;
           })
        |> Js.Promise.then_(_ =>
             Js.log(
               {j|EventTopic: Published event $idx/$eventCount: $eventName($id) to $name: $event|j},
             )
             ->Js.Promise.resolve
           );
      })
      |> Js.Promise.all
      |> Js.Promise.then_(_ => Js.Promise.resolve());
    };

  let construct = (~storageResources, self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let publisher =
      Publisher.make(
        ~name=name->ComponentType.name(componentType),
        ~storageResources,
        ~opts,
      );

    self->setPublish(publisher->publishFn(name));

    makeOutputs(~resources=publisher.resources) |> self->setOutputs;
  };

  let make = (~name, ~storageResources, ~opts=?, _) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~storageResources),
      ~opts,
    );
};
