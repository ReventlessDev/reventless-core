type outputs = {resource: Adapter.resource}

type createSchedule = (array<Adapter.resolvedResource>, Schedule.schedule) => promise<unit>
type deleteSchedule = (array<Adapter.resolvedResource>, string) => promise<unit>

type operations = {
  createSchedule: createSchedule,
  deleteSchedule: deleteSchedule,
}
