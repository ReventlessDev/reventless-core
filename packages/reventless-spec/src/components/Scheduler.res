type outputs = {resource: Adapter.resource}

type createSchedule = (array<Adapter.unwrappedResource>, Schedule.schedule) => promise<unit>
type deleteSchedule = (array<Adapter.unwrappedResource>, string) => promise<unit>

type operations = {
  createSchedule: createSchedule,
  deleteSchedule: deleteSchedule,
}
