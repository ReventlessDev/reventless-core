/**
Module type for an aggregate's identity and schema specification.

Every aggregate defines a `Spec` module satisfying this type. The `Spec` is
used by `Platform.Aggregate.Make` and by `Behavior.T` to fix the aggregate's
command, event, and error types.

@example
```rescript
// Category.res
module Id = Id.String
let name = "Category"

@schema
type command =
  | AddCategory({categoryId: string, name: string})
  | RenameCategory({categoryId: string, name: string})
  | ArchiveCategory({categoryId: string})

@schema
type event =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

@schema
type error =
  | CategoryAlreadyExists
  | CategoryNotFound
  | CategoryAlreadyArchived
```
*/
module type Spec = {
  module Id: Id.T

  /** Logical aggregate name used as a prefix for infrastructure resource names. */
  let name: string

  /** Commands this aggregate accepts. Must carry `@schema`. */
  @schema
  type command

  /** Events this aggregate emits. Must carry `@schema`. */
  @schema
  type event

  /** Business rule violation errors. Must carry `@schema`. */
  @schema
  type error
}

/**
A function that attaches an additional `EventMapper` to this aggregate after it has
been provisioned. Used by the plugin assembly to wire cross-aggregate event routing.
*/
type rec addEventMapper = (EventTopic.allOutputs, QueryEngine.operations) => outputs

/**
Deploy-time outputs produced when an `Aggregate` is provisioned.

- `name` — the aggregate's logical name
- `commandGenerator` — the internal command dispatcher component
- `commandTopic` — the SQS FIFO queue for inbound commands
- `eventLog` — the DynamoDB event store
- `eventMapper` — optional: the event-to-command router (present when mappings are configured)
- `addEventMapper` — callback used by the plugin to attach late-bound event mappers
*/
and outputs = {
  name: string,
  commandGenerator: Pulumi.Output.t<CommandGenerator.outputs>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventLog: EventLog.outputs,
  eventMapper?: Pulumi.Output.t<EventMapper.outputs>,
  addEventMapper: addEventMapper,
}

/** A dictionary of aggregate outputs keyed by aggregate name. */
type allOutputs = dict<outputs>

/**
Runtime operations exposed by an `Aggregate` component.

Obtained via `Component.operations(aggregate)`. Available inside Lambda handlers.
*/
type operations = {
  /** Publish a batch of serialized commands to this aggregate's command topic. */
  publishJsons: CommandTopic.publishJsons,
  /** Publish a stream of serialized commands (for high-throughput pipelines). */
  publishJsonsStream: CommandTopic.publishJsonsStream,
}

/**
Module type produced by `Platform.Aggregate.Make(Spec, Behavior, Mappings)`.

The resulting module exposes `make` for instantiating the aggregate at deploy time
and `operations` for publishing commands at runtime.

@example
```rescript
// CatalogPlugin.res
module CategoryAggregate = Platform.Aggregate.Make(
  Category,
  CategoryBehavior,
  NoEventMappings.Make(Category),
)

// Deploy time
let category = CategoryAggregate.make(~api, ~opts=?)

// Runtime — inside a Lambda handler
let ops = await category->Component.operations->TestRunner.resolve
await ops.publishJsons([{id: "cat-1", meta, commandJson: json}])
```
*/
module type T = {
  module Spec: Spec
  type api
  type component
  let make: (~api: api, ~opts: Pulumi.ComponentResource.options=?) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  /** Signal that all event mappers have been attached; finalises the aggregate. */
  let finish: unit => unit
}
