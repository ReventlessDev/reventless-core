/**
A field whose large value lives in a content-addressed object store, carried by
reference — or inline when it is small enough not to be worth a round trip.

## Sibling of `StorageRef`, not the same thing

`StorageRef` and `Offload` are two members of one family: both say "this field's
value lives in an object store", both declare that store through the shared
`Semantic.StoredIn` marker, and both are produced by a **client** that uploads
the bytes before the command is issued — never by the framework inside `decide`.
They differ in what the field carries:

- `@storageRef` is always a reference (an origin-relative path a store minted),
  and the reference *is* the value the reader sees (a URL it renders).
- `@offload` is an **inline-or-reference** value. Below a size threshold the
  value stays embedded; above it the client stores the bytes under a
  content-addressed key and the field carries `Offloaded{store, key, hash, bytes}`.
  A reader resolves either arm back to the value.

Content addressing (the key is the SHA-256 of the bytes) makes the store write
idempotent and deduplicating: the same value stored twice lands on the same key,
so identical payloads across versions or tenants hold one object, not many.

## The backward-compatible wire form

Every event already in history stored the value **inline and unwrapped** — a
plain record, with no variant tag. So the codec here must decode those bytes
unchanged, which rules out sury's default tagged-union encoding (`{TAG, _0}`).

Instead the codec is *untagged* and sniffs a reserved sentinel key:

- an `Offloaded` value encodes as `{"$offload": {store, key, hash, bytes}}`;
- an `Inline` value encodes as the raw value, exactly as before.

On decode, a JSON object carrying the `$offload` key is an `Offloaded`; anything
else is decoded as the inner value into `Inline`. A record field name can never
be `$offload` (identifiers cannot start with `$`), so a legacy inline payload can
never be mistaken for a reference, and vice versa — no migration, and a
pre-change fixture decodes as `Inline` untouched.

@example
```rescript
// an event/command field, optional and offloadable to the "pluginStructures" store
structure: @s.matches(Offload.optionSchema(~store="pluginStructures", pluginStructureSchema))
  option<Offload.payload<pluginStructure>>
```
*/

/** The reference an offloaded value carries: which store holds it, the
    content-addressed key, the content hash (== the key's basis), and the byte
    length. `hash` is redundant with `key` today (`key` is `sha256/<hash>`) but
    named so a reader can verify integrity without parsing the key. */
@schema
type offloadedRef = {
  store: string,
  key: string,
  hash: string,
  bytes: int,
}

/** A field's value: embedded, or a reference to bytes the client stored. */
type payload<'a> =
  | Inline('a)
  | Offloaded(offloadedRef)

/** `nullableAsOption` emits `T | undefined | null`, which fails
    `jsonableValidation` inside an event union; `js_nullable` emits `T | null`,
    which is JSON-safe there. Same reason `Plugin.res` reaches for it. */
@module("sury/src/Sury.res.mjs")
external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"

/** The codec builds on `S.json`, which sury 11 gates behind an explicit enable.
    Doing it here (at module load, before any `schema` call) makes the primitive
    self-contained: importing `Offload` is enough, no consumer has to remember. */
S.enableJson()

/** The object key under which an `Offloaded` value hides. Reserved: no ReScript
    record field encodes to a key starting with `$`, so it cannot collide with an
    inline payload's own fields. */
let sentinelKey = "$offload"

/**
The untagged inline-or-reference codec for a field of inner type `'a`.

Parameterised by the inner value's schema because the `Inline` arm round-trips
through it. The `Offloaded` arm round-trips through `offloadedRefSchema` under the
sentinel key. See the module doc for why this is untagged.
*/
let schema = (inner: S.t<'a>): S.t<payload<'a>> => {
  // Offloaded arm: recognised by the reserved sentinel key, strict, and tried
  // first so an offloaded value is never mistaken for an inline one. The ref is
  // a fixed new shape that needs no healing, so a direct json-transform is fine.
  let offloadedArm = S.json->S.transform(s => {
    parser: json =>
      switch json->JSON.Decode.object->Option.flatMap(dict => dict->Dict.get(sentinelKey)) {
      | Some(refJson) => Offloaded(refJson->S.parseJsonOrThrow(offloadedRefSchema))
      | None => s.fail("not an offloaded reference")
      },
    serializer: payload =>
      switch payload {
      | Offloaded(ref) =>
        Dict.fromArray([(sentinelKey, ref->S.reverseConvertToJsonOrThrow(offloadedRefSchema))])
        ->JSON.Encode.object
      | Inline(_) => s.fail("not an offloaded reference")
      },
  })
  // Inline arm: the inner schema applied through sury's own pipeline, so it
  // inherits whatever tolerance the surrounding decode uses — the lifecycle
  // Message decoder heals older payloads with missing fields. This is why the
  // codec is a union rather than one json-transform with a nested
  // parseJsonOrThrow: a nested parse runs strict and breaks the frozen corpus.
  let inlineArm = inner->S.transform(s => {
    parser: value => Inline(value),
    serializer: payload =>
      switch payload {
      | Inline(value) => value
      | Offloaded(_) => s.fail("not an inline value")
      },
  })
  S.union([offloadedArm, inlineArm])
}

/**
The codec plus the `StoredIn` marker declaring which store the field's references
live in, for a **non-optional** field. `plugin` is absent for the declaring
plugin's own store; qualify as `"<plugin>.<store>"` to point at another's.

Prefer the `@offload("<store>")` ppx shorthand over calling this by hand.
*/
let forStore = (~plugin: option<string>=?, ~store: string, inner: S.t<'a>): S.t<payload<'a>> =>
  schema(inner)->Semantic.mark(~id=Semantic.Id.offload, ~payload=StoredIn({plugin, store}))

/**
The codec wrapped for an **optional** field (`js_nullable`), plus the `StoredIn`
marker. This is the common case: offloadable fields are usually optional (absent
for older protocol versions, say). The marker sits on the outer schema, where
`Semantic.get` reads it first.
*/
let optionSchema = (
  ~plugin: option<string>=?,
  ~store: string,
  inner: S.t<'a>,
): S.t<option<payload<'a>>> =>
  _jsNullable(schema(inner), ())->Semantic.mark(
    ~id=Semantic.Id.offload,
    ~payload=StoredIn({plugin, store}),
  )

/** The inline value, if this payload is `Inline`. `None` for `Offloaded` — a
    caller that must handle both arms uses `resolve` (async, fetches the ref); a
    caller that only ever sees inline values (a test, or a path where offloading
    is not yet wired) uses this. */
let getInline = (payload: payload<'a>): option<'a> =>
  switch payload {
  | Inline(value) => Some(value)
  | Offloaded(_) => None
  }

// ── Client helpers ─────────────────────────────────────────────────────────
//
// The producer/reader surface that makes offloading easy for a client to drive.
// Both take their store I/O as injected transports so this module stays pure
// and provider-agnostic: a browser passes a presigned PUT / fetch, the Node seed
// passes a direct SDK call, a test passes an in-memory map. The plugin's own
// deploy-time producer is the exception — it offloads Pulumi-natively (declares a
// content-addressed object resource) rather than through `prepare`, because its
// value is a `Pulumi.Output` and a resource cannot be created inside `.apply`.

/**
Decide inline-or-offloaded for one value and, when it is large, upload it.

Serializes `value` with `schema`; if the JSON is below `threshold` it stays
`Inline` (no round trip). Otherwise it is hashed, uploaded under the
content-addressed key `sha256/<hash>`, and returned as `Offloaded`. Because the
key is the content hash, re-uploading identical bytes writes the same object —
idempotent, and the source of cross-version/cross-client dedupe.

`~hash` and `~upload` are injected so this stays provider-agnostic; `~hash` must
be a stable content hash (the same bytes must always hash the same). Size is the
JSON string's length in characters — a close proxy for byte length on the
mostly-ASCII JSON these payloads are, and only ever used for the threshold cut.
*/
let prepare = (
  value: 'a,
  ~schema: S.t<'a>,
  ~store: string,
  ~threshold: int,
  ~hash: string => string,
  ~upload: (~key: string, ~bytes: string) => promise<unit>,
): promise<payload<'a>> => {
  let bytes = value->S.reverseConvertToJsonStringOrThrow(schema)
  if bytes->String.length < threshold {
    Promise.resolve(Inline(value))
  } else {
    let digest = hash(bytes)
    let key = "sha256/" ++ digest
    upload(~key, ~bytes)->Promise.then(() =>
      Promise.resolve(Offloaded({store, key, hash: digest, bytes: bytes->String.length}))
    )
  }
}

/**
Resolve a payload back to its value: `Inline` directly, `Offloaded` by fetching
the object's bytes (via the injected `~fetch`) and decoding with `schema`.

Offloaded objects are written by current code, so their bytes decode strictly —
unlike the inline arm of the wire codec, which heals older event payloads.
*/
let resolve = (payload: payload<'a>, ~schema: S.t<'a>, ~fetch: string => promise<string>): promise<
  'a,
> =>
  switch payload {
  | Inline(value) => Promise.resolve(value)
  | Offloaded({key}) =>
    fetch(key)->Promise.then(bytes => Promise.resolve(bytes->S.parseJsonStringOrThrow(schema)))
  }

/**
Wrap a `~fetch` so each content-addressed key is fetched at most once per process.

Keys are immutable (they are content hashes), so a fetched object can be cached
forever — every replay/projection that references the same hash reuses it, and
concurrent resolves of the same key share the one in-flight promise.
*/
let cachedFetch = (fetch: string => promise<string>): (string => promise<string>) => {
  let cache: dict<promise<string>> = Dict.make()
  key =>
    switch cache->Dict.get(key) {
    | Some(inflight) => inflight
    | None =>
      let inflight = fetch(key)
      cache->Dict.set(key, inflight)
      inflight
    }
}

/** The store an `@offload` field declares, if any — the read side of the marker,
    used by provisioning to know the field requires this store to exist. Distinct
    from `StorageRef.getStore` by the semantic id, so the two families stay
    separable (offload objects are content-addressed and durable up front; they
    must not be swept by the pending-upload claimer). */
let getStore = (schema: S.t<'a>): option<Semantic.storeTarget> =>
  switch Semantic.get(schema) {
  | Some({id, payload: StoredIn(target)}) if id == Semantic.Id.offload => Some(target)
  | _ => None
  }
