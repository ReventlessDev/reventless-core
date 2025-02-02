type createSchedule = (array<Adapter.resource>, Schedule.schedule) => Js.Promise.t<unit>
type deleteSchedule = (array<Adapter.resource>, string) => Js.Promise.t<unit>

type functions = {createSchedule: createSchedule, deleteSchedule: deleteSchedule}
type t = functions
