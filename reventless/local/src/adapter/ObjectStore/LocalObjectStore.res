// Object store dispatcher backing the dev platform's served-bucket routes.
//
// The AWS path fronts a private S3 bucket through CloudFront (served-buckets
// plan); in dev there is no bucket, so objects live wherever the active storage
// backend keeps its state — the store follows the events rather than choosing
// its own durability:
//   - a file-backed SQLite database → ObjectStoreStorage_FileSystem, writing
//     beside the database (`./.reventless/objects`, `./.reventless/offload`)
//   - Memory, `:memory:` SQLite, Postgres → ObjectStoreStorage_InMemory
// BackendState.getObjectStoreRoot makes that choice; the arms are consulted per
// call rather than at a `make`, since this store has no construction step and a
// suite may flip the backend between tests.
//
// Held outside EventLog/QueryDb storage because it is raw bytes, not event or
// query state — hence the `Local` prefix on the dispatcher, and `_InMemory` /
// `_FileSystem` on the arms (not `_Sqlite`: the durable arm is the filesystem,
// anchored to the database's directory).

type entry = {
  bytes: NodeBuffer.t,
  contentType: string,
}

// The prefix the local upload route mints keys under. Mirrors the AWS presign
// `SERVED_PREFIX` (default "uploads"); the hybrid example uses "uploads".
let defaultUploadPrefix = "uploads"

// Prefixes the dev server serves at `/{prefix}/*` (PUT stores, GET reads).
// Seeded with the default upload prefix; a deployment serving another prefix
// registers it before the servers start.
let servedPrefixes: ref<array<string>> = ref([defaultUploadPrefix])

let registerServedPrefix = (prefix: string): unit =>
  if !(servedPrefixes.contents->Array.includes(prefix)) {
    servedPrefixes.contents = servedPrefixes.contents->Array.concat([prefix])
  }

// A request path is a served-object path when its first segment is a registered
// served prefix and at least one key segment follows. Returns the storage key
// (the path without its leading slash), or None for GraphQL / other paths.
//
// `..`, `.` and empty segments are refused here rather than inside the storage
// arms so that every caller — the HTTP routes and Upload_Release alike — agrees
// on which paths exist, whichever backend is active. Under the filesystem arm a
// key becomes a path, and `uploads/../../etc/passwd` would otherwise escape the
// store.
let servedKey = (path: string): option<string> => {
  let trimmed = path->String.startsWith("/") ? path->String.slice(~start=1, ~end=path->String.length) : path
  let segments = trimmed->String.split("/")
  let prefix = segments->Array.get(0)->Option.getOr("")
  if (
    prefix->String.length > 0 &&
    servedPrefixes.contents->Array.includes(prefix) &&
    trimmed->String.length > prefix->String.length + 1 &&
    segments->Array.every(seg => seg != "" && seg != "." && seg != "..")
  ) {
    Some(trimmed)
  } else {
    None
  }
}

let put = (~key: string, ~bytes: NodeBuffer.t, ~contentType: string): unit =>
  switch BackendState.getObjectStoreRoot() {
  | Some(root) => ObjectStoreStorage_FileSystem.put(~root, ~key, ~bytes, ~contentType)
  | None => ObjectStoreStorage_InMemory.put(~key, ~bytes, ~contentType)
  }

let get = (~key: string): option<entry> => {
  let stored = switch BackendState.getObjectStoreRoot() {
  | Some(root) => ObjectStoreStorage_FileSystem.get(~root, ~key)
  | None => ObjectStoreStorage_InMemory.get(~key)
  }
  stored->Option.map(((bytes, contentType)) => {bytes, contentType})
}

// Remove a stored object. Idempotent — deleting an absent key is a no-op, matching
// the release contract (see docs/plans/done/upload-release-path.md, Step 3). The dev
// store has no identities or clock, so the release resolver enforces only the
// *shape* of the rule (key under a served prefix), not the identity/age conditions.
let delete = (~key: string): unit =>
  switch BackendState.getObjectStoreRoot() {
  | Some(root) => ObjectStoreStorage_FileSystem.delete(~root, ~key)
  | None => ObjectStoreStorage_InMemory.delete(~key)
  }

// ── Offload objects ───────────────────────────────────────────────────────
// Content-addressed deploy-time objects (`sha256/<hash>`), holding the large
// pluginDefinition fields the connect handshake carries by reference instead of
// inline. Deliberately a separate keyspace from the served objects: on AWS these
// live in a private bucket the ComponentDefinitions Lambda reads through the SDK,
// never behind a served route, so they must not become reachable over
// `/{prefix}/*` here either. Bytes are the value's JSON, kept as a string because
// that is what `Offload.resolve`'s `fetch` hands back.

let putOffload = (~key: string, ~bytes: string): unit =>
  switch BackendState.getObjectStoreRoot() {
  | Some(root) => ObjectStoreStorage_FileSystem.putOffload(~root, ~key, ~bytes)
  | None => ObjectStoreStorage_InMemory.putOffload(~key, ~bytes)
  }

let getOffload = (~key: string): option<string> =>
  switch BackendState.getObjectStoreRoot() {
  | Some(root) => ObjectStoreStorage_FileSystem.getOffload(~root, ~key)
  | None => ObjectStoreStorage_InMemory.getOffload(~key)
  }

// Clear stored objects and restore the default served prefix. Called between
// isolated test suites (from DomainGraphQL_Server.reset) and at Platform
// construction under `sqlite:…?reset`, where wiping the events has to wipe the
// bytes they reference too. Clears both arms: the backend is chosen before
// construction, but a suite that flips backends can leave state in either.
let reset = (): unit => {
  ObjectStoreStorage_InMemory.reset()
  switch BackendState.getObjectStoreRoot() {
  | Some(root) => ObjectStoreStorage_FileSystem.reset(~root)
  | None => ()
  }
  servedPrefixes.contents = [defaultUploadPrefix]
}
