open ReventlessSpec.Adapter;

let componentType = ComponentType.EventTopic;

type outputs = {. "publisher": resource};

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

  type t;

  let make:
    (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) =>
    Component.t(t, outputs);

  let publish: Component.t(t, outputs) => publish(Spec.Id.t, Spec.event);
};

module Adapter = {
  let publisher = "Publisher";
  type publisher = {
    resource,
    publish: (. string, Message.meta, Js.Json.t) => Js.Promise.t(unit),
  };
  type publisherMaker =
    (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => publisher;

  module type Publisher = {let make: publisherMaker;};

  let setPublisherResource = (resource, name) =>
    resource->Resources.set(
      ~adapter=publisher,
      ~name=name->ComponentType.name(componentType),
    );
  let getPublisherResource = name =>
    Resources.getExn(
      ~adapter=publisher,
      ~name=name->ComponentType.name(componentType),
    );
};

module Make =
       (Spec: Spec, Publisher: Adapter.Publisher)
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type constructed;
  type construct = (Component.t(t, outputs), string) => constructed;

  type nonrec publish = publish(Spec.Id.t, Spec.event);

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

  [@bs.obj] external makeOutputs: (~publisher: resource) => outputs = "";

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
  external setPublish: (Component.t(t, outputs), publish) => unit = "publish";
  [@bs.get] external publish: Component.t(t, outputs) => publish = "publish";

  let publishFn = publisher =>
    (. events') => {
      let eventCount = events'->Belt.Array.length;
      events'->Belt.Array.mapWithIndex((idx, event') => {
        let json =
          Message.event'_encode(Spec.Id.t_encode, Spec.event_encode, event');

        let id = event'.id;
        let event = json->Js.Json.stringify;
        let eventName: string = event'.event->Spec.event_encode->Obj.magic[0];
        let idx = idx + 1;
        let resourceName = publisher.Adapter.resource##name->Pulumi.Output.get;

        publisher.publish(. id->Spec.Id.toString, event'.meta, json)
        |> Js.Promise.catch(e => {
             Js.log(
               {j|EventTopic: Couldn't publish event $idx/$eventCount: $eventName($id) to $resourceName|j},
             );
             NotPublishedToPublisher(e)->Js.Promise.reject;
           })
        |> Js.Promise.then_(_ =>
             Js.log(
               {j|EventTopic: Published event $idx/$eventCount: $eventName($id) to $resourceName: $event|j},
             )
             ->Js.Promise.resolve
           );
      })
      |> Js.Promise.all
      |> Js.Promise.then_(_ => Js.Promise.resolve());
    };

  let construct = (self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let publisher =
      Publisher.make(~name=name->ComponentType.name(componentType), ~opts);
    publisher.resource->Adapter.setPublisherResource(name);
    let publisherOutputs = publisher.resource;

    self->setPublish(publisher->publishFn);

    makeOutputs(~publisher=publisherOutputs) |> self->setOutputs;
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
