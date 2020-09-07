let componentType = ComponentType.Scheduler;

[@decco]
type year = int;
[@decco]
type month = int;
[@decco]
type day = int;
[@decco]
type hour = int;
[@decco]
type minute = int;

[@decco]
type rate =
  | Single(year, month, day, hour, minute)
  | Minutes(int)
  | Hours(int)
  | Days(int)
  | Daily(hour, minute)
  | Weekdays(hour, minute);

[@decco]
type schedule = {
  name: string,
  rate,
  payload: string,
};

type target = {
  id: string,
  urn: string,
};

type createSchedule = (. target, schedule) => Js.Promise.t(unit);
type deleteSchedule = (. target, string) => Js.Promise.t(unit);

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

type scheduledPublisher = {
  resource: Adapter.resource,
  createSchedule,
  deleteSchedule,
};

module type ScheduledPublisher = {
  let make:
    (~name: string, ~opts: Pulumi.CustomResourceOptions.t) =>
    scheduledPublisher;
};

module Make = (ScheduledPublisher: ScheduledPublisher) : T => {
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
  external makeOutputs: (~scheduledPublisher: Adapter.resource) => outputs =
    "";

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

    self->setCreateSchedule(scheduledPublisher.createSchedule);
    self->setDeleteSchedule(scheduledPublisher.deleteSchedule);

    makeOutputs(~scheduledPublisher=scheduledPublisher.resource)
    |> self->setOutputs;
  };

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
    (~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=componentType->ComponentType.toString,
        ~construct,
        ~opts,
      );
    };
};
