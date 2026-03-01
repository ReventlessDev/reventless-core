/**
Module type for an aggregate's event log specification.

`EventLog.T` is used by the framework to configure the event storage backend
(e.g. a DynamoDB table) and the associated event topic for downstream subscribers.
*/
module type T = {
  module Id: Id.T

  /** Logical name of the aggregate / event stream (used as a table-name prefix). */
  let name: string

  /** The event type stored in this log. Must carry `@schema` for serialization. */
  @schema
  type event
}

/**
Deploy-time outputs produced when an `EventLog` is provisioned.

- `resources` — the underlying infrastructure resources (e.g. DynamoDB table)
- `eventTopic` — the event topic outputs for downstream subscribers
*/
type outputs = {resources: array<Adapter.resource>, eventTopic: EventTopic.outputs}
