/**
A function that attaches an additional `EventMapper` to this aggregate after it has
been provisioned. Used by the plugin assembly to wire cross-aggregate event routing.
*/
type rec addEventMapper = (EventTopic.allOutputs, Reventless.QueryEngine.operations) => outputs

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
  module Spec: Reventless.Aggregate.Spec
  type api
  type component
  let make: (
    ~api: api,
    ~runtime: RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  /** Signal that all event mappers have been attached; finalises the aggregate. */
  let finish: unit => unit
}
