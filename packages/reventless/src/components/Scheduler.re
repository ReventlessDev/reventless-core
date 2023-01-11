open ReventlessSpec.Schedule;
open ReventlessSpec.Adapter;

let componentType = ComponentType.Scheduler;

type createSchedule = (. array(resource), schedule) => Js.Promise.t(unit);
type deleteSchedule = (. array(resource), string) => Js.Promise.t(unit);

type functions = {
  .
  "createSchedule": createSchedule,
  "deleteSchedule": deleteSchedule,
};

type outputs = {.};
external toOutputs: functions => outputs = "%identity";

type t = functions;

module type T = {
  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
};

module Adapter = {
  let publisher = "Publisher";
  type scheduledPublisher = {
    resource,
    create: createSchedule,
    delete: deleteSchedule,
  };
  type scheduledPublisherMaker =
    (~name: string, ~opts: Pulumi.CustomResourceOptions.t) =>
    scheduledPublisher;

  module type ScheduledPublisher = {let make: scheduledPublisherMaker;};
};

module Make = (ScheduledPublisher: Adapter.ScheduledPublisher) : T => {
  type constructed;
  type construct = (t, string) => constructed;

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
  external makeOutputs: (~scheduledPublisher: resource) => outputs = "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set]
  external setCreateSchedule: (t, createSchedule) => unit = "createSchedule";
  [@bs.set]
  external setDeleteSchedule: (t, deleteSchedule) => unit = "deleteSchedule";

  let construct = (self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let scheduledPublisher = ScheduledPublisher.make(~name, ~opts);

    self->setCreateSchedule(scheduledPublisher.create);
    self->setDeleteSchedule(scheduledPublisher.delete);

    makeOutputs(~scheduledPublisher=scheduledPublisher.resource)
    |> self->setOutputs;
  };

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
    (~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=componentType->ComponentType.toName,
        ~construct,
        ~opts,
      );
    };
};
