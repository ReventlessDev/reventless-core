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
Why a command was refused.

`DomainRejection` is `Decision.decide` returning `Error` — the model declining the command,
which is the model working. `InfrastructureFailure` is the decision never landing: an event-log
append that failed outright or exhausted its conflict retries. Both arrive on `reportRejected`,
so without this a consumer would read a broken event log as a business rejection.

`AccessRefusal` is the handler refusing before `decide` runs, because the caller does not
own what the command acts on (`OwnerScope.decideActing`).
*/
type refusalCause = DomainRejection | InfrastructureFailure | AccessRefusal

/** What became of one command, as the producer that waited for it hears it. */
type commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>, cause: refusalCause})
  | Pending({msgId: string})

/**
Publishes commands and waits for each one's outcome, in order. A target that answers
inline gives `Accepted` or `Rejected`; one that does not gives `Pending`.
*/
type publishJsonsAndWait = array<Reventless.Message.commandJson> => promise<array<commandOutcome>>

/**
Publishes a stream of serialized command envelopes as an `Effect.t`.
Use this for high-throughput or streaming command pipelines.
*/
type publishJsonsStream = Stream.t<Reventless.Message.commandJson, string, unit> => Effect.t<
  unit,
  string,
  unit,
>

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
