open ReventlessSpec.Adapter;

let componentType = ComponentType.EventTopic;

type outputs = {. "resources": array(resource)};

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
    (
      ~name: string,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let publish: Component.t(t, outputs) => publish(Spec.Id.t, Spec.event);
};

module Adapter = {
  type publisher = {
    resources: array(resource),
    publish: (. string, Message.meta, Js.Json.t) => Js.Promise.t(unit),
  };
  type publisherMaker =
    (
      ~name: string,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    publisher;

  module type Publisher = {let make: publisherMaker;};
};

module Make =
       (Spec: Spec, Publisher: Adapter.Publisher)
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type constructed;
  type construct =
    (Component.t(t, outputs), string, resources) => constructed;

  type nonrec publish = publish(Spec.Id.t, Spec.event);

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
  external makeOutputs: (~resources: array(resource)) => outputs = "";

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
        let resourceName =
          publisher.Adapter.resources[0]##name->Pulumi.Output.get; // FIXME

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

  let construct = (self, name, resources) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let publisher =
      Publisher.make(
        ~name=name->ComponentType.name(componentType),
        ~opts,
        ~resources,
      );

    self->setPublish(publisher->publishFn);

    makeOutputs(~resources=publisher.resources) |> self->setOutputs;
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
