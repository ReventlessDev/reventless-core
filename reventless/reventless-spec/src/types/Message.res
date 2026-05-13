S.enableJson()

/** Identifies the service that produced or is addressed by a message. */
@schema
type service = string

/**
Envelope metadata attached to every event and command.

Every message that flows through Reventless carries this metadata so that
audit trails, correlation, distributed tracing, and routing are available
without inspecting the domain payload.

Shared by both `event'<>` and `command'<>` envelopes — fields are kept
generic so they apply equally to commands and events.

@example
```rescript
let meta: Message.meta = {
  service: "CatalogService",
  time: "2024-01-01T00:00:00Z",
  msgId: "msg-abc",
  correlationId: "cmd-xyz",
  user: "alice",
}
```
*/
@schema
type meta = {
  /** Name of the service that created or is addressed by this message. */
  service: service,
  /** ISO-8601 timestamp of when the message was created (producer time). */
  time: string,
  /** IP address of the service instance that created the message. Absent when unknown
      (e.g. serverless contexts without a caller IP). */
  ip?: string,
  /** Identity of the actor who initiated the action. Absent for system-initiated messages. */
  user?: string,
  /** Unique identifier for this message. */
  msgId: string,
  /** Identifier of the root message of the correlation chain. Always present;
      defaults to `msgId` when this is the root. */
  correlationId: string,
  /** Identifier of the *direct* parent message that caused this one. Absent at the chain root. */
  causationId?: string,
  /** W3C Trace Context `traceparent` header value (opaque pass-through).
      Intentionally all-lowercase: matches the HTTP header name, OpenTelemetry SDKs,
      and the CloudEvents distributed-tracing extension. */
  traceparent?: string,
  /** Schema version stamp for this message's payload variant. Absent = unversioned. */
  schemaVersion?: string,
  /** Extensible header bag for cross-cutting context (tenantId, feature flags, etc.).
      Absent when empty — consumers normalise with `->Option.getOr(Dict.make())`. */
  headers?: dict<string>,
}

/**
Context passed into command handlers, carrying the aggregate ID and envelope metadata.

Passed as the second argument to `Behavior.T.create` and `Behavior.T.execute`
so business logic can read the caller identity or propagate correlation IDs.
*/
@schema
type context = {
  id: string,
  meta: meta,
}

/**
A domain event envelope pairing an aggregate ID with the event payload and metadata.

The generic parameters `'id` and `'event` are fixed by each aggregate's `Spec`:
- `'id` comes from `Spec.Id.t`
- `'event` comes from `Spec.event`

@example
```rescript
let ev: Message.event'<string, Category.event> = {
  id: "cat-1",
  meta,
  event: CategoryAdded({categoryId: "cat-1", name: "Electronics"}),
}
```
*/
type event'<'id, 'event> = {
  id: 'id,
  meta: meta,
  event: 'event,
}

/**
Records who changed a resource's status and when.
Useful in audit-trail projections (e.g. "approved by bob at 2024-01-15").
*/
@schema
type statusChange = {
  at: string,
  by: string,
}

/**
A command envelope pairing an aggregate ID with the command payload and metadata.

@example
```rescript
let cmd: Message.command'<string, Category.command> = {
  id: "cat-1",
  meta,
  command: AddCategory({categoryId: "cat-1", name: "Electronics"}),
}
```
*/
type command'<'id, 'command> = {
  id: 'id,
  meta: meta,
  command: 'command,
}

/**
A serialized command envelope used when routing commands across service boundaries.

`commandJson` holds the raw JSON payload encoded by sury. The optional `delay`
field specifies a delivery delay in seconds (used by the scheduler).

@example
```rescript
let queued: Message.commandJson = {
  id: "cat-1",
  meta,
  commandJson: json,
  delay: Some(5),
}
```
*/
@schema
type commandJson = {
  id: string,
  meta: meta,
  commandJson: JSON.t,
  delay?: int,
}

/**
Decode a JSON value into `'a` using a sury schema. Throws on parse failure.

@example
```rescript
let event = json->Message.decode(Category.eventSchema)
```
*/
let decode = (json, schema: S.t<'a>) => json->S.parseJsonOrThrow(schema)

/**
Encode a value to JSON using a sury schema.

@example
```rescript
let json = event->Message.encode(Category.eventSchema)
```
*/
let encode = (value, schema: S.t<'a>) => value->S.reverseConvertToJsonOrThrow(schema)

/** Raised by adapters when an incoming event JSON cannot be matched to a known event variant. */
exception InvalidEvent(JSON.t)

let toEventSchema' = (idSchema, eventSchema) =>
  S.object(s => {
    id: s.field("id", idSchema),
    meta: s.field("meta", metaSchema),
    event: s.field("event", eventSchema),
  })

/** Decode a raw event JSON envelope into a typed `event'<'id, 'event>`. */
let decodeEvent' = (json, idSchema, eventSchema) =>
  json->S.parseJsonOrThrow(toEventSchema'(idSchema, eventSchema))

/** Extract the variant constructor name from a sury-encoded variant JSON. */
let variantNameOfJson = json =>
  switch json {
  | JSON.String(str) => str
  | Object(dict) =>
    switch dict->Dict.get("TAG") {
    | Some(String(tag)) => tag
    | _ => "unknown"
    }
  | _ => "unknown"
  }

/** Compose a raw event JSON envelope from id, meta, and event JSON. */
let composeEventJson' = (id, meta, eventJson) =>
  [
    ("id", id->JSON.Encode.string),
    ("meta", meta->S.reverseConvertToJsonOrThrow(metaSchema)),
    ("event", eventJson),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object
