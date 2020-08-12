let componentType = ComponentType.EventTopic;

type publish('data) = (. 'data) => Js.Promise.t(unit);

type functions('id, 'event) = {
  .
  "publish": publish(array(Message.event'('id, 'event))),
};

type outputs = {. "publisher": Adapter.resource};
external toOutputs: functions('id, 'command) => outputs = "%identity";

type t('id, 'command) = functions('id, 'command);

exception NotPublishedToPublisher(Js.Promise.error);

module type Spec = {
  module Id: Id.T;

  let name: string;

  [@decco]
  type event;
};

module type T = {
  module Spec: Spec;

  type nonrec t = t(Spec.Id.t, Spec.event);

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
};

type publisher = {
  resource: Adapter.resource,
  publish: publish(Js.Json.t),
};

module type Publisher = {
  let make:
    (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => publisher;
};

module Make = (Spec: Spec, Publisher: Publisher) : (T with module Spec = Spec) => {
  module Spec = Spec;
  type nonrec t = t(Spec.Id.t, Spec.event);

  type constructed;
  type construct = (t, string) => constructed;

  type nonrec publish =
    publish(array(Message.event'(Spec.Id.t, Spec.event)));

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

  [@bs.obj]
  external makeOutputs: (~publisher: Adapter.resource) => outputs = "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setPublish: (t, publish) => unit = "publish";

  let publish = publisher =>
    (. events') => {
      let eventCount = events' |> Array.length;
      events'
      |> Array.mapi((idx, event') => {
           let json =
             Message.event'_encode(
               Spec.Id.t_encode,
               Spec.event_encode,
               event',
             );

           let id = event'.id;
           let event = json->Js.Json.stringify;
           let eventName: string = event'.event->Spec.event_encode->Obj.magic[0];
           let idx = idx + 1;
           let resourceName = publisher.resource##name->Pulumi.Output.get;

           publisher.publish(. json)
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
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let publisher = Publisher.make(~name, ~opts);
    let publisherOutputs = publisher.resource;

    self->setPublish(publisher->publish);

    makeOutputs(~publisher=publisherOutputs) |> self->setOutputs;
  };

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
    (~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name->ComponentType.name(componentType),
        ~construct,
        ~opts,
      );
    };
};
