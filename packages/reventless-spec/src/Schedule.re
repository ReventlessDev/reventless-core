type create = (. Scheduler.schedule) => Js.Promise.t(unit);
type delete = (. /*~name:*/ string) => Js.Promise.t(unit);

exception ScheduleNotCreated(Scheduler.schedule, string, Js.Promise.error);
exception ScheduleNotDeleted(string, string, Js.Promise.error);
