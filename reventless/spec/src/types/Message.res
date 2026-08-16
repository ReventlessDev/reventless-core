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

// ── Schema-migration-on-read ──────────────────────────────────────────────────
// Nested `@schema` types (notably `pluginDefinition`/`pluginStructure`) gain fields
// over time — `kind`, `chapter`, `events`, `extensionPoints`, `apiExposed`, … Because
// those types are JSON-encoded inside union-variant payloads, every optional field must
// use the `js_nullable` (`T | null`) encoding: it is the only JSON-safe optional form,
// since `S.option`/`nullableAsOption` carry `undefined`, which fails sury's
// `jsonableValidation` inside a union variant. That encoding is *present-required on
// decode*, so ONE message persisted before a field was added SuryError-bricks decode. For
// an aggregate that rehydrates from its own event log (the Plugin lifecycle aggregate),
// that single event then freezes EVERY later heartbeat/redetect/connect on that instance
// — a silent lifecycle freeze with no error surfaced near the operator.
//
// We heal on read. Strict decode stays the fast path (unchanged for every current
// message); only when it throws do we schema-guide the raw JSON and retry once. The fill
// walks the target sury schema and inserts, for any absent field, the value that field's
// schema expects: `null` for a `T | null` union (→ `None`), `[]` for a missing array, the
// first variant of a mandatory enum (`kind` → `Domain`), a filled `{}` for a missing
// nested object, and a zero value for a missing scalar. It descends only into values
// actually present, matches tagged-union members by their `TAG` const, is purely additive
// (clones via a JSON round-trip; never re-encodes through the schema), is idempotent on
// valid data, and falls back to the ORIGINAL error when the fill doesn't resolve the
// failure — so genuine corruption still surfaces.
// See docs/plans/done/platform-infrastructure-in-plugin-list.md (durable fix option 2).
//
// The scalar arm is the odd one out and is deliberately noisy. Every other fill is
// *derived* — the schema states what an absent value means, and the fill supplies exactly
// that. A scalar has no such statement, so `""` / `0` / `false` is a value this code
// invented: right for a descriptive field added later, wrong for a field that carries
// meaning. It also widens what can be masked, since a genuinely truncated payload now
// decodes where it used to throw. Every scalar fill is therefore reported to the caller
// and logged, so healing stays findable instead of becoming the silent default. Without
// it, a required-scalar addition freezes an aggregate outright — see
// docs/analysis/plugin-definition-schema-evolution-wedge.md.
//
// `bigint` is excluded on purpose: it has no JSON representation, so any value invented
// here would fail the retry anyway and mask the real error path.
//
// `scalarFills` is an out-parameter: the walker pushes `path := value` for each scalar it
// invented.
let fillMissingDefaults: (S.t<'a>, JSON.t, array<string>) => JSON.t = %raw(`function(schema, json, scalarFills){
  function isSchema(x){ return x && typeof x === "object" && typeof x.type === "string"; }
  function firstConst(anyOf){ var m=(anyOf||[]).find(function(s){return s.const!==undefined;}); return m ? m.const : undefined; }
  function scalarDefault(schema){
    if(schema.const!==undefined) return schema.const;
    switch(schema.type){
      case "string": return "";
      case "number": return 0;
      case "boolean": return false;
      default: return undefined;
    }
  }
  function fill(schema, value, path){
    if(!isSchema(schema)) return value;
    switch(schema.type){
      case "object": {
        if(value===undefined){ value={}; }
        else if(value===null || typeof value!=="object" || Array.isArray(value)) return value;
        var items=schema.items||[];
        for(var i=0;i<items.length;i++){ var it=items[i]; value[it.location]=fill(it.schema, value[it.location], path+"."+it.location); }
        return value;
      }
      case "array": {
        if(Array.isArray(value)){ var el=schema.additionalItems; return isSchema(el) ? value.map(function(v,ix){return fill(el,v,path+"["+ix+"]");}) : value; }
        if(value===undefined) return [];
        return value;
      }
      case "union": {
        var has=schema.has||{};
        if(value===undefined){
          if(has.null) return null;
          var c=firstConst(schema.anyOf); if(c!==undefined) return c;
          var obj=(schema.anyOf||[]).find(function(s){return s.type==="object";}); if(obj) return fill(obj,{},path);
          return undefined;
        }
        if(value===null) return null;
        var members=schema.anyOf||[];
        if(Array.isArray(value)){ var a=members.find(function(s){return s.type==="array";}); return a ? fill(a,value,path) : value; }
        if(typeof value==="object"){
          var m=members.find(function(s){return s.type==="object" && (s.items||[]).some(function(it){return it.location==="TAG" && it.schema.const===value.TAG;});});
          if(!m) m=members.find(function(s){return s.type==="object";});
          return m ? fill(m,value,path) : value;
        }
        return value;
      }
      default: {
        if(value!==undefined) return value;
        var d=scalarDefault(schema);
        if(d===undefined) return value;
        scalarFills.push(path + " := " + JSON.stringify(d));
        return d;
      }
    }
  }
  // Clone via JSON round-trip (json is already pure JSON) so the caller's value is never mutated.
  return fill(schema, JSON.parse(JSON.stringify(json)), "");
}`)

// Strict parse with a single schema-migration-on-read retry (see fillMissingDefaults).
let parseJsonTolerant = (json, schema) =>
  switch json->S.parseJsonOrThrow(schema) {
  | value => value
  | exception firstErr =>
    let scalarFills = []
    switch fillMissingDefaults(schema, json, scalarFills)->S.parseJsonOrThrow(schema) {
    | value =>
      // Only the invented values are worth a line. A heal that used nothing but
      // schema-derived defaults is the mechanism working as designed.
      if scalarFills->Array.length > 0 {
        Console.warn(
          `[reventless] decoded a stored message by inventing ${scalarFills
            ->Array.length
            ->Int.toString} missing scalar field(s): ${scalarFills->Array.join(
              ", ",
            )}. A required scalar was added to a persisted type after this message was ` ++
          `written; the value above is fabricated, not recovered. Prefer a js_nullable (T | null) field.`,
        )
      }
      value
    | exception _ => throw(firstErr)
    }
  }

/**
Decode a JSON value into `'a` using a sury schema.

Strict decode is the fast path; on failure it applies a single schema-migration-on-read
retry (see `fillMissingDefaults`) so a message persisted before a nested `@schema` field
existed still decodes instead of bricking. Re-throws the original error if the fill does
not resolve the failure.

@example
```rescript
let event = json->Message.decode(Category.eventSchema)
```
*/
let decode = (json, schema: S.t<'a>) => json->parseJsonTolerant(schema)

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

/** Decode a raw event JSON envelope into a typed `event'<'id, 'event>`. Tolerant on
    read (see `fillMissingDefaults`) so envelopes persisted before a nested field existed
    still decode. */
let decodeEvent' = (json, idSchema, eventSchema) =>
  json->parseJsonTolerant(toEventSchema'(idSchema, eventSchema))

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
