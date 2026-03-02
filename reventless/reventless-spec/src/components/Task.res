/**
Derives the name used to query a task's S3 bucket.

- `~taskName` — the task's logical name
- `~bucketName` — optional override; defaults to the task's configured bucket name
*/
type queryBucketName = (~taskName: string, ~bucketName: string=?) => string

/**
An action that a task handler can return after processing a trigger.

- `PublishCommands(aggregateName, commands)` — publish commands to an aggregate
- `CreateSchedule(schedule)` — create a new recurring or one-time schedule
- `DeleteSchedule(name)` — delete a schedule by name
*/
type taskAction =
  | PublishCommands(string, array<Message.commandJson>)
  | CreateSchedule(Schedule.schedule)
  | DeleteSchedule(string)

/**
A callback invoked when an S3 object event occurs on a task bucket.

- `~eventName` — the S3 event type (e.g. `"ObjectCreated:Put"`)
- `~key` — the S3 object key that triggered the event

Returns an array of `taskAction` values to execute after the callback completes.
*/
type bucketCallback = (~eventName: string, ~key: string) => promise<array<taskAction>>

/**
The access mode a task needs for one of its S3 buckets.

- `Read` — task reads from the bucket (e.g. to import catalog data)
- `Write` — task writes to the bucket (e.g. to export a report)
- `ReadWrite` — task reads and writes
*/
type bucketMode = Read | Write | ReadWrite

/**
Configuration for one S3 bucket used by a task.

- `bucketName` — optional override; if absent, the framework derives a name
- `bucketMode` — the required access level
- `callback` — optional handler triggered by S3 object events
*/
type bucketSpec = {bucketName?: string, bucketMode: bucketMode, callback?: bucketCallback}

/** An array of `SideEffect.T` modules executed when this task fires. */
type sideEffects = array<module(SideEffect.T)>

/**
The runtime configuration returned by a task's `setup` function.

- `buckets` — optional list of S3 bucket specifications
- `sideEffects` — optional list of side effect modules to execute
*/
type config = {
  buckets?: array<bucketSpec>,
  sideEffects?: sideEffects,
}

