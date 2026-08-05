// On-disk arm of the local object store: bytes under the same directory the
// SQLite database lives in, so uploads and offloaded payloads survive a restart
// exactly like the events that reference them.
//
// The two were previously out of step: with `REVENTLESS_LOCAL_BACKEND=sqlite` an
// event carrying an `Offloaded{store, key, …}` reference outlived the bytes it
// pointed at, so a restart replayed events whose payloads had evaporated.
//
// Layout, rooted at the SQLite file's directory (`./.reventless` by convention):
//
//   objects/<key>            served-object bytes; the key's slashes become real
//                            directories, so the tree mirrors the URL space the
//                            dev server serves at /{prefix}/*
//   object-meta/<key>.json   {"contentType": …} for that object
//   offload/<key>            content-addressed offload payload (JSON text)
//
// Content type needs a sidecar because a file holds bytes and nothing else.
// Keeping it in a PARALLEL tree rather than beside the object leaves `objects/`
// an exact mirror of what is served — no `.json` companions to skip when
// browsing, copying, or serving it directly.
//
// Every call is synchronous, matching the in-memory arm's signature: this is a
// dev-only store on a local disk, and going async here would push promises
// through the HTTP handlers and the offload hook for no benefit.

let objectsDir = (~root) => NodePath.join([root, "objects"])
let metaDir = (~root) => NodePath.join([root, "object-meta"])
let offloadDir = (~root) => NodePath.join([root, "offload"])

// A key becomes a path here, so it must not climb out of the root. Keys arrive
// from URL paths as well as from content addressing, and `..` segments that were
// inert as dict keys are not inert as path segments.
let isSafeKey = (key: string): bool =>
  key != "" &&
  !(key->String.startsWith("/")) &&
  key->String.split("/")->Array.every(seg => seg != "" && seg != "." && seg != "..")

let writeUnder = (path: string, write: string => unit): unit => {
  NodeFs.mkdirSync(NodePath.dirname(path), {recursive: true})
  write(path)
}

// Drop directories the deleted object left behind, walking up until one still
// holds something or `stopAt` is reached. S3 has no directories, so the empty
// `<uuid>/` a released upload leaves is an artifact of the filesystem mapping,
// not something the AWS path would have.
let rec pruneEmptyDirs = (~stopAt: string, ~from: string): unit =>
  if from != stopAt && from->String.length > stopAt->String.length {
    let entries = try NodeFs.readdirSync(from, {withFileTypes: true}) catch {
    | _ => []
    }
    if entries->Array.length == 0 {
      try NodeFs.rmSync(from, {recursive: true, force: true}) catch {
      | _ => ()
      }
      pruneEmptyDirs(~stopAt, ~from=NodePath.dirname(from))
    }
  }

// ── Served objects ──────────────────────────────────────────────────────────

let objectPath = (~root, ~key) => NodePath.join([objectsDir(~root), key])
let metaPath = (~root, ~key) => NodePath.join([metaDir(~root), key ++ ".json"])

let put = (~root: string, ~key: string, ~bytes: NodeBuffer.t, ~contentType: string): unit =>
  if isSafeKey(key) {
    writeUnder(objectPath(~root, ~key), path => NodeFs.writeFileSyncBuffer(path, bytes))
    writeUnder(metaPath(~root, ~key), path =>
      NodeFs.writeFileSync(
        path,
        Dict.fromArray([("contentType", JSON.Encode.string(contentType))])
        ->JSON.Encode.object
        ->JSON.stringify,
      )
    )
  }

let defaultContentType = "application/octet-stream"

let readContentType = (~root, ~key): string =>
  switch try Some(NodeFs.readFileSync(metaPath(~root, ~key))) catch {
  | _ => None
  } {
  | Some(raw) =>
    raw
    ->JSON.parseOrThrow
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("contentType"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr(defaultContentType)
  | None => defaultContentType
  }

// The try covers the case where the key names a directory rather than a file
// (`/uploads/<uuid>` when only `/uploads/<uuid>/logo.svg` was stored): reading it
// throws EISDIR, and the answer the caller wants is the same 404 a missing key
// gets.
let get = (~root: string, ~key: string): option<(NodeBuffer.t, string)> =>
  if !isSafeKey(key) {
    None
  } else {
    switch try Some(NodeFs.readFileSyncBuffer(objectPath(~root, ~key))) catch {
    | _ => None
    } {
    | Some(bytes) => Some((bytes, readContentType(~root, ~key)))
    | None => None
    }
  }

let removeFile = (path: string): unit =>
  try NodeFs.unlinkSync(path) catch {
  | _ => ()
  }

let delete = (~root: string, ~key: string): unit =>
  if isSafeKey(key) {
    let object = objectPath(~root, ~key)
    let meta = metaPath(~root, ~key)
    removeFile(object)
    removeFile(meta)
    pruneEmptyDirs(~stopAt=objectsDir(~root), ~from=NodePath.dirname(object))
    pruneEmptyDirs(~stopAt=metaDir(~root), ~from=NodePath.dirname(meta))
  }

// ── Offload objects ─────────────────────────────────────────────────────────

let offloadPath = (~root, ~key) => NodePath.join([offloadDir(~root), key])

let putOffload = (~root: string, ~key: string, ~bytes: string): unit =>
  if isSafeKey(key) {
    writeUnder(offloadPath(~root, ~key), path => NodeFs.writeFileSync(path, bytes))
  }

let getOffload = (~root: string, ~key: string): option<string> =>
  if !isSafeKey(key) {
    None
  } else {
    try Some(NodeFs.readFileSync(offloadPath(~root, ~key))) catch {
    | _ => None
    }
  }

// Removes the three trees, leaving the rest of the root (the database file, the
// dev `users.yaml`) untouched.
let reset = (~root: string): unit =>
  [objectsDir(~root), metaDir(~root), offloadDir(~root)]->Array.forEach(dir =>
    try NodeFs.rmSync(dir, {recursive: true, force: true}) catch {
    | _ => ()
    }
  )
