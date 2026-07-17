// Logical envelope for an event as it lives in storage (EventLog or DcbEventLog).
// The DynamoDB adapters flatten `meta` to top-level item attributes so meta keys
// stay GSI-projectable; the in-memory adapter stores the nested record as-is.
//
// This is the single source of truth for the on-disk shape — both
// EventLog_Operations and DcbEventLogStorage_DynamoDb_Runtime go through it
// rather than building Dict items by hand.

/**
A stored event record. Used by both backends:
- Aggregate EventLog: `id` is the aggregate id, `position` is the zero-padded sequence string, `tags` is absent.
- DcbEventLog: `id` is the synthesised partition key (derived from tags), `position` is "<unixMs>-<uuid>", `tags` is present.

`event` is the variant constructor name (the on-disk "event" column).
`data` is the sury-encoded variant payload with the TAG discriminator stripped.
`recordedAt` is the storage timestamp, set by the storage adapter at append.
*/
type storedEvent<'id> = {
  id: 'id,
  position: string,
  event: string,
  data: JSON.t,
  meta: Message.meta,
  recordedAt: string,
  tags?: array<DcbTag.tag>,
}

/** Build a sury schema for `storedEvent<'id>` given the `'id` schema. */
let toStoredEventSchema = (idSchema: S.t<'id>): S.t<storedEvent<'id>> =>
  S.object(s => {
    id: s.field("id", idSchema),
    position: s.field("position", S.string),
    event: s.field("event", S.string),
    data: s.field("data", S.json),
    meta: s.field("meta", Message.metaSchema),
    recordedAt: s.field("recordedAt", S.string),
    tags: ?s.field("tags", S.option(S.array(DcbTag.tagSchema))),
  })

/** Decode a `storedEvent<'id>` from JSON. */
let decode = (json, idSchema) =>
  json->S.parseJsonOrThrow(toStoredEventSchema(idSchema))

/** Encode a `storedEvent<'id>` to JSON. */
let encode = (stored, idSchema) =>
  stored->S.reverseConvertToJsonOrThrow(toStoredEventSchema(idSchema))
