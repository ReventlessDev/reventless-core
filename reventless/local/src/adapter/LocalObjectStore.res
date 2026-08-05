// Process-local object store backing the dev platform's served-bucket routes.
//
// The AWS path fronts a private S3 bucket through CloudFront (served-buckets
// plan); in dev there is no bucket, so uploaded and served objects live in this
// process-local map. Ephemeral by design — contents are lost on restart, which
// matches the plan's dev-only, non-durable stance. Held here (not in
// EventLog/QueryDb storage) because it is raw bytes, not event/query state, and
// has no SQLite arm — hence the `Local` prefix and no `_InMemory` suffix.

// Node Buffer, opaque here — produced by the PUT handler (concat of request
// chunks) and handed straight back to the response by the GET handler.
type buffer

@val @scope("Buffer") external concatBuffers: array<buffer> => buffer = "concat"

type entry = {
  bytes: buffer,
  contentType: string,
}

let objects: dict<entry> = Dict.make()

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
let servedKey = (path: string): option<string> => {
  let trimmed = path->String.startsWith("/") ? path->String.slice(~start=1, ~end=path->String.length) : path
  let prefix = trimmed->String.split("/")->Array.get(0)->Option.getOr("")
  if (
    prefix->String.length > 0 &&
    servedPrefixes.contents->Array.includes(prefix) &&
    trimmed->String.length > prefix->String.length + 1
  ) {
    Some(trimmed)
  } else {
    None
  }
}

let put = (~key: string, ~bytes: buffer, ~contentType: string): unit =>
  objects->Dict.set(key, {bytes, contentType})

let get = (~key: string): option<entry> => objects->Dict.get(key)

// Remove a stored object. Idempotent — deleting an absent key is a no-op, matching
// the release contract (see docs/plans/done/upload-release-path.md, Step 3). The dev
// store has no identities or clock, so the release resolver enforces only the
// *shape* of the rule (key under a served prefix), not the identity/age conditions.
let delete = (~key: string): unit => objects->Dict.delete(key)

// ── Offload objects ───────────────────────────────────────────────────────
// Content-addressed deploy-time objects (`sha256/<hash>`), holding the large
// pluginDefinition fields the connect handshake carries by reference instead of
// inline. Deliberately a separate keyspace from `objects`: on AWS these live in
// a private bucket the ComponentDefinitions Lambda reads through the SDK, never
// behind a served route, so they must not become reachable over `/{prefix}/*`
// here either. Bytes are the value's JSON, kept as a string because that is
// what `Offload.resolve`'s `fetch` hands back.
let offloadObjects: dict<string> = Dict.make()

let putOffload = (~key: string, ~bytes: string): unit => offloadObjects->Dict.set(key, bytes)

let getOffload = (~key: string): option<string> => offloadObjects->Dict.get(key)

// Clear stored objects and restore the default served prefix — used between
// isolated test suites (called from DomainGraphQL_Server.reset).
let reset = (): unit => {
  objects->Dict.keysToArray->Array.forEach(k => objects->Dict.delete(k))
  offloadObjects->Dict.keysToArray->Array.forEach(k => offloadObjects->Dict.delete(k))
  servedPrefixes.contents = [defaultUploadPrefix]
}
