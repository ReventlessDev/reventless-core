/**
Module type for an aggregate's command topic specification.

`CommandTopic.T` is used by the framework to identify the command channel
(e.g. an SQS FIFO queue) and validate that published commands match the
aggregate's command schema.
*/
module type T = {
  module Id: Reventless.Id.T

  /** Logical name of the aggregate or component owning this command topic. */
  let name: string

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
type publishJsons = array<Reventless.Message.commandJson> => promise<unit>

/**
Publishes a stream of serialized command envelopes as an `Effect.t`.
Use this for high-throughput or streaming command pipelines.
*/
type publishJsonsStream = Stream.t<Reventless.Message.commandJson, string, unit> => Effect.t<unit, string, unit>

/**
A command together with an idempotency reference string.

Used by the extension point runtime to track which commands have already
been processed and avoid duplicate dispatch.
*/
type topicItem<'command> = {
  command: 'command,
  reference: string,
}

/**
A handler that processes a stream of typed topic items and returns an Effect
producing per-item results.

`commandsHandler<JSON.t>` is the JSON-level variant used for routing;
`commandsHandler<Reventless.Message.command'<Id.t, command>>` is the decoded variant
used by aggregate and slice callbacks.
*/
type commandsHandler<'command> = Stream.t<topicItem<'command>, string, unit> => Effect.t<
  array<result<string, string>>,
  string,
  unit,
>
