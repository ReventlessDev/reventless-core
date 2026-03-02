/**
Deploy-time outputs produced when a `Scheduler` component is provisioned.
Contains the single infrastructure resource backing the scheduler (e.g. EventBridge Scheduler).
*/
type outputs = {resource: Adapter.resource}

/**
Creates a schedule in the underlying scheduling service (e.g. EventBridge Scheduler).

- `array<Adapter.resolvedResource>` — resolved scheduler resources (ARNs, etc.)
- `Reventless.Schedule.schedule` — the schedule definition to create
*/
type createSchedule = (array<Adapter.resolvedResource>, Reventless.Schedule.schedule) => promise<unit>

/**
Deletes a schedule by name from the underlying scheduling service.

- `array<Adapter.resolvedResource>` — resolved scheduler resources
- `string` — the name of the schedule to delete
*/
type deleteSchedule = (array<Adapter.resolvedResource>, string) => promise<unit>

/**
Runtime operations exposed by a `Scheduler` component.

Injected into extension points, tasks, and the plugin to create or delete
schedules dynamically at runtime.
*/
type operations = {
  createSchedule: createSchedule,
  deleteSchedule: deleteSchedule,
}
