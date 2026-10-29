/** Generates a new UUID v4 string. */
@module("uuid") @val
external uuid: unit => string = "v4"

/** The namespace `deriveStableMeta` mints ids in: one fixed value, so the same
    input gives the same id in every process. */
let derivedIdNamespace = Uuid.Namespace.custom("c4e9c2e6-8b3f-4f0e-9a52-6d2b4c7e1a90")

/**
The meta of a message a mapping derives from `parent`.

The envelope is the one `deriveMeta` documents: `causationId` is the parent's
`msgId`, `correlationId` and the tracing fields are inherited, `service` is the
emitter. The `msgId` is a function of the input: the parent's `msgId`, the
emitter and the action's `index` in the mapping's result (`item` for one command
of a multi-command action). A mapping run again on the same input produces the
same ids, which is what lets a handler recognize a redelivered fact; two inputs
or two actions of one input never collide.
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
  headers: ?parent.headers,
}
