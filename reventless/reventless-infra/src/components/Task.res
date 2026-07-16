/**
Derives the name used to query a task's S3 bucket.

- `~taskName` — the task's logical name
- `~bucketName` — optional override; defaults to the task's configured bucket name
*/
type queryBucketName = (~taskName: string, ~bucketName: string=?) => string

/**
The `setup` function signature for a `Task.Spec`.

Called at deploy time to configure the task's infrastructure.
Receives the query engine, bucket name helper, and Pulumi options.
Returns the task's runtime `config`.
*/
type setup = (
  Reventless.QueryEngine.operations,
  queryBucketName,
  Pulumi.ComponentResource.options,
) => Reventless.Task.config

/**
Module type for a task's specification.

A `Task` is a serverless handler triggered by S3 events or schedules.
It can publish commands, manage schedules, and execute side effects.

@example
```rescript
module CatalogImportTask: Task.Spec = {
  let name = "CatalogImport"
  let setup = (_queryEngine, _queryBucketName, _opts) => {
    buckets: [{bucketMode: Read}],
    sideEffects: [],
  }
}
```
*/
module type Spec = {
  /** Logical task name (used as a Lambda function name prefix). */
  let name: string
  /** ESM specifier for this Spec module — populated by `@@reventless.task` PPX. */
  let moduleUrl: string
  let setup: setup
}

/**
Deploy-time outputs produced when a `Task` is provisioned.

- `name` — the task's logical name
- `bucketNames` — resolved S3 bucket names keyed by bucket spec index
- `sideEffectSources` — names of aggregate event sources wired to side effects
*/
type outputs = {
  name: string,
  bucketNames?: dict<Pulumi.Output.t<string>>,
  sideEffectSources?: array<string>,
}

/**
Runtime operations exposed by a `Task` component.
Allows the task handler to publish commands to aggregates by name.
*/
type operations = {
  publishCommands: (string, array<Reventless.Message.commandJson>) => promise<unit>,
}

/**
Module type produced by `Platform.Task.Make(Spec)`.
*/
module type T = {
  module Spec: Spec
  type component
  let make: (
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.operations,
    /** URN identifying the principal/role the scheduler invokes targets as.
        Bundled adapters thread this into the runtime config so the deployed
        handler can call the underlying scheduler service. Adapters without
        a real scheduler (e.g. in-memory) ignore it. */
    ~schedulerRoleUrn: Pulumi.Output.t<string>,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~resourceNaming: ResourceNaming.operations,
    ~allAggregates: dict<Aggregate.outputs>,
    ~runtime: RuntimeHints.t=?,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
}
