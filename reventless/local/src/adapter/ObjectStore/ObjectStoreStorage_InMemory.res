// In-process arm of the local object store: two dicts, wiped on restart.
//
// Selected when nothing durable is on local disk (Memory backend, a `:memory:`
// SQLite, Postgres) — see BackendState.getObjectStoreRoot. Ephemeral by design:
// with the events themselves gone on restart, the bytes they reference have
// nothing to outlive.
//
// `get` returns a `(bytes, contentType)` pair rather than a record so that this
// arm and ObjectStoreStorage_FileSystem share one signature without either
// owning a type the other must import; LocalObjectStore names the pair.

type stored = (NodeBuffer.t, string)

let objects: dict<stored> = Dict.make()

let put = (~key: string, ~bytes: NodeBuffer.t, ~contentType: string): unit =>
  objects->Dict.set(key, (bytes, contentType))

let get = (~key: string): option<stored> => objects->Dict.get(key)

let delete = (~key: string): unit => objects->Dict.delete(key)

// Offload payloads: a separate keyspace, for the reason LocalObjectStore gives.
let offloadObjects: dict<string> = Dict.make()

let putOffload = (~key: string, ~bytes: string): unit => offloadObjects->Dict.set(key, bytes)

let getOffload = (~key: string): option<string> => offloadObjects->Dict.get(key)

let reset = (): unit => {
  objects->Dict.keysToArray->Array.forEach(k => objects->Dict.delete(k))
  offloadObjects->Dict.keysToArray->Array.forEach(k => offloadObjects->Dict.delete(k))
}
