/**
Module type for an aggregate's command topic specification.

`CommandTopic.T` is used by the framework to identify the command channel
(e.g. an SQS FIFO queue) and validate that published commands match the
aggregate's command schema.
*/
module type T = {
  module Id: Id.T

  /** The command type published to this topic. Must carry `@schema` for serialization. */
  @schema
  type command
}

/**
Deploy-time outputs produced when a `CommandTopic` is provisioned.
Contains the underlying queue / messaging infrastructure resources.
*/
type outputs = {resources: array<Adapter.resource>}

/** A dictionary of command topic outputs keyed by aggregate name. */
type allOutputs = dict<outputs>

/**
Publishes an array of serialized command envelopes to this command topic.

Commands are batched for efficiency. Each `Message.commandJson` carries
the aggregate ID, metadata, raw JSON payload, and optional delivery delay.

@example
```rescript
await ops.publishJsons([{id: "cat-1", meta, commandJson: json}])
```
*/
type publishJsons = array<Message.commandJson> => promise<unit>

/**
Publishes a stream of serialized command envelopes as an `Effect.t`.
Use this for high-throughput or streaming command pipelines.
*/
type publishJsonsStream = Stream.t<Message.commandJson, string, unit> => Effect.t<unit, string, unit>

/**
A command together with an idempotency reference string.

Used by the extension point runtime to track which commands have already
been processed and avoid duplicate dispatch.
*/
type topicItem<'command> = {
  command: 'command,
  reference: string,
}
