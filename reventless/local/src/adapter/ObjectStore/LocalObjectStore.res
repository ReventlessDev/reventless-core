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

// The prefix keys are minted under when no declared store claims them. Mirrors
// the AWS presign `SERVED_PREFIX` default; it stays served even once every store
// declares its own prefix, because refs already minted under it live in an
// append-only event log and must keep resolving.
let defaultUploadPrefix = "uploads"

// Prefixes the dev server serves at `/{prefix}/*` (PUT stores, GET reads).
// Seeded with the default upload prefix; declared stores add their own.
let servedPrefixes: ref<array<string>> = ref([defaultUploadPrefix])

let registerServedPrefix = (prefix: string): unit =>
  if !(servedPrefixes.contents->Array.includes(prefix)) {
    servedPrefixes.contents = servedPrefixes.contents->Array.concat([prefix])
  }

// Declared object stores, `{plugin}.{store}` → the prefix its keys are rooted at
// (`StoreLayout.keyPrefixFor`). The deployed platform threads the same map into
// its presign service as `UPLOAD_STORES`; here the Platform fills it from every
// connected plugin's `requiredStores`.
//
// Rooting keys at the declaring store — rather than dropping every plugin's
// uploads into one `uploads/` space — is what makes an object attributable: a
// scoped wipe reads the plugin back off the key prefix, exactly as it does from
// an S3 key.
let declaredStores: dict<string> = Dict.make()

/** Where a declared store's objects sit locally: the deployed `{plugin}/{store}`
    layout NESTED under the served `uploads/` prefix.

    The nesting is not cosmetic. A dev UI is served by its own dev server and
    reaches the platform through a proxy that forwards one path — `/uploads` — so a
    ref minted outside it resolves against the UI server instead of the platform,
    and the image silently renders as the SPA shell. Keeping every object under
    `uploads/` means the serve path is a property of the platform, not something
    each UI dev server has to be reconfigured to know. The `{plugin}/{store}`
    segments still carry the attribution a scoped reset reads back off the key. */
let localPrefixFor = (~qualified: string): string =>
  `${defaultUploadPrefix}/${ReventlessCore.StoreLayout.prefixOfQualified(qualified)}`

let registerStore = (~qualified: string, ~prefix: string): unit => {
  declaredStores->Dict.set(qualified, prefix)
  registerServedPrefix(prefix)
}

let storePrefix = (~qualified: string): option<string> => declaredStores->Dict.get(qualified)

let declaredStoreList = (): array<(string, string)> => declaredStores->Dict.toArray

// A request path is a served-object path when it sits under a registered served
// prefix with at least one key segment following. Returns the storage key (the
// path without its leading slash), or None for GraphQL / other paths.
//
// Matches the prefix as a path, not as a first segment: a declared store's
// prefix is `{plugin}/{store}` — two segments — while the default `uploads` is
// one, and both have to resolve through the same route.
//
// `..`, `.` and empty segments are refused here rather than inside the storage
// arms so that every caller — the HTTP routes and Upload_Release alike — agrees
// on which paths exist, whichever backend is active. Under the filesystem arm a
// key becomes a path, and `uploads/../../etc/passwd` would otherwise escape the
// store.
let servedKey = (path: string): option<string> => {
  let trimmed = path->String.startsWith("/") ? path->String.slice(~start=1, ~end=path->String.length) : path
  let segments = trimmed->String.split("/")
  let underAPrefix =
    servedPrefixes.contents->Array.some(p =>
      p->String.length > 0 && trimmed->String.startsWith(p ++ "/") && trimmed->String.length > p->String.length + 1
    )
  if underAPrefix && segments->Array.every(seg => seg != "" && seg != "." && seg != "..") {
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
  declaredStores->Dict.keysToArray->Array.forEach(k => declaredStores->Dict.delete(k))
}
