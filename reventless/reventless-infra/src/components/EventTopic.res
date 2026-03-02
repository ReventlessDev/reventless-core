/**
Module type for an aggregate's event topic specification.

`EventTopic.T` is used by the framework to identify the event channel
(e.g. an SNS topic) and validate that published events match the
aggregate's event schema.
*/
module type T = {
  module Id: Reventless.Id.T

  /** The event type published to this topic. Must carry `@schema` for serialization. */
  @schema
  type event
}

/**
Deploy-time outputs produced when an `EventTopic` is provisioned.
Contains the underlying messaging infrastructure resources.
*/
type outputs = {resources: array<Adapter.resource>}

/** A dictionary of event topic outputs keyed by aggregate name. */
type allOutputs = dict<outputs>

/**
Publishes a single event as raw JSON to the event topic.

- `string` — the aggregate ID (as a plain string)
- `Message.meta` — the event envelope metadata
- `JSON.t` — the serialized event payload
*/
type publishJson = (string, Reventless.Message.meta, JSON.t) => promise<unit>

/**
An item in a streaming event publication batch.
Passed to `publishJsonStream` for high-throughput event pipelines.
*/
type publishJsonStreamItem = {
  service: string,
  meta: Reventless.Message.meta,
  json: JSON.t,
}

/**
Publishes a stream of event items as an `Effect.t`.
Use this for high-throughput or streaming event pipelines.
*/
type publishJsonStream = Stream.t<publishJsonStreamItem, string, unit> => Effect.t<unit, string, unit>
