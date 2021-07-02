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
  | Weekdays(hour, minute)
  | WeekdaysAndSaturday(hour, minute);

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

type t = functions;

type scheduledPublisher = {
  resource: Adapter.resource,
  createSchedule,
  deleteSchedule,
};
type scheduledPublisherMaker =
  (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => scheduledPublisher;

module type ScheduledPublisher = {let make: scheduledPublisherMaker;};
