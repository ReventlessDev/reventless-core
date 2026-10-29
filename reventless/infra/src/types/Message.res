/** Generates a new UUID v4 string. */
@module("uuid") @val
external uuid: unit => string = "v4"

/** The namespace `deriveStableMeta` mints ids in: one fixed value, so the same
    input gives the same id in every process. */
let derivedIdNamespace = Uuid.Namespace.custom("c4e9c2e6-8b3f-4f0e-9a52-6d2b4c7e1a90")

/** The header `deriveStableMeta` sets, which marks a message whose `msgId` is a
    function of its input. A handler reads it as "a repeat of this command can be
    recognized", and `deriveMeta` strips it so the mark never outlives the id. */
let stableIdHeader = "reventless-stable-id"

/** Whether this message's `msgId` was derived from its input, so that a second
    delivery carries the same id. */
let hasStableMsgId = (meta: Reventless.Message.meta): bool =>
  meta.headers->Option.flatMap(h => h->Dict.get(stableIdHeader))->Option.isSome

let withStableIdHeader = (headers: option<dict<string>>): dict<string> => {
  let out = headers->Option.mapOr(Dict.make(), Dict.copy)
  out->Dict.set(stableIdHeader, "true")
  out
}

/** The inherited headers without the stable-id mark: a message whose id is fresh
    must not claim otherwise. `None` when nothing is left. */
let withoutStableIdHeader = (headers: option<dict<string>>): option<dict<string>> =>
  switch headers {
  | Some(h) if h->Dict.has(stableIdHeader) =>
    let out = h->Dict.copy
    out->Dict.delete(stableIdHeader)
    out->Dict.keysToArray->Array.length == 0 ? None : Some(out)
  | other => other
  }

/**
The meta of a message a mapping derives from `parent`.

The envelope is the one `deriveMeta` documents: `causationId` is the parent's
`msgId`, `correlationId` and the tracing fields are inherited, `service` is the
emitter. The `msgId` is a function of the input: the parent's `msgId`, the
emitter and the action's `index` in the mapping's result (`item` for one command
of a multi-command action). A mapping run again on the same input produces the
same ids, which is what lets a handler recognize a redelivered fact; two inputs
or two actions of one input never collide. The `stableIdHeader` marks the result.
*/
let deriveStableMeta = (
  ~parent: Reventless.Message.meta,
  ~service,
  ~index,
  ~item=0,
): Reventless.Message.meta => {
  service,
  time: Date.make()->Date.toISOString,
  msgId: Uuid.v5(
    ~name=`${parent.msgId}/${service}/${index->Int.toString}/${item->Int.toString}`,
    ~namespace=derivedIdNamespace,
  ),
  correlationId: parent.correlationId,
  causationId: parent.msgId,
  ip: ?parent.ip,
  user: ?parent.user,
  traceparent: ?parent.traceparent,
  schemaVersion: ?parent.schemaVersion,
  headers: withStableIdHeader(parent.headers),
}
