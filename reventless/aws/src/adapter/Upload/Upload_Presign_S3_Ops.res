// Runtime handler for the upload service — compiled, type-checked, and Pulumi-free
// so it can be shipped as an EntryPoint module (`Upload_Presign_S3` bundles it and
// attaches it as the platform API's `Upload_Presign`/`Upload_Release` Lambda data
// source). Keeping it out of the deploy-time module is what avoids both the
// serialized-closure SDK skew and the deploy-time Pulumi import leaking into the
// Lambda's cold-start graph.
//
// Invoked by an AppSync resolver, not a Function URL: the platform API's Cognito
// authorizer has already authenticated the caller, so the verified `sub` arrives in
// the resolver's identity context. There is no token to decode and no anonymous
// surface — the earlier `decodeJwtSub` path is gone.
//
// Two operations dispatch on the `operation` field the resolver bakes in:
//   presign → derive `{servedPrefix}/{sub}/{uuid}/{fileName}`, presign a PUT to the
//             store's bucket (expires 300s), return `{uploadUrl, storageRef}`.
//   release → apply the release rule (scope + age) to a `storageRef` and, if it
//             passes, `DeleteObject`; return `{released, reason}`.
// Bytes never touch this Lambda — only presign metadata and release decisions do.

// ── AWS SDK v3 bindings ─────────────────────────────────────────────────────

type s3Client

type putObjectInput = {
  @as("Bucket") bucket: string,
  @as("Key") key: string,
  @as("ContentType") contentType?: string,
}
type putObjectCommand

type deleteObjectInput = {
  @as("Bucket") bucket: string,
  @as("Key") key: string,
}
type deleteObjectCommand

type headObjectInput = {
  @as("Bucket") bucket: string,
  @as("Key") key: string,
}
type headObjectCommand
type headObjectOutput = {@as("LastModified") lastModified?: Date.t}

@module("@aws-sdk/client-s3") @new external makeS3Client: unit => s3Client = "S3Client"

@module("@aws-sdk/client-s3") @new
external makePutObjectCommand: putObjectInput => putObjectCommand = "PutObjectCommand"

@module("@aws-sdk/client-s3") @new
external makeDeleteObjectCommand: deleteObjectInput => deleteObjectCommand = "DeleteObjectCommand"

@module("@aws-sdk/client-s3") @new
external makeHeadObjectCommand: headObjectInput => headObjectCommand = "HeadObjectCommand"

@send external sendDelete: (s3Client, deleteObjectCommand) => promise<unit> = "send"
@send external sendHead: (s3Client, headObjectCommand) => promise<headObjectOutput> = "send"

type presignOptions = {expiresIn: int}

@module("@aws-sdk/s3-request-presigner")
external getSignedUrl: (s3Client, putObjectCommand, presignOptions) => promise<string> =
  "getSignedUrl"

// ── Environment ─────────────────────────────────────────────────────────────

// Read an env var, mapping "" / unset to None.
let getEnv = (k: string): option<string> =>
  switch NodeProcess.env->Dict.get(k) {
  | Some("") | None => None
  | Some(v) => Some(v)
  }

// A store the service can presign into / release from: its physical bucket and the
// prefix its keys are rooted at. Threaded in as `UPLOAD_STORES`, a JSON object keyed
// by the qualified `{plugin}.{store}` the caller names, so one Lambda serves every
// declared store while its IAM stays scoped to their prefixes.
type storeConfig = {
  bucket: string,
  prefix: string,
}

let decodeStore = (json: JSON.t): option<storeConfig> =>
  switch json {
  | Object(obj) =>
    switch (
      obj->Dict.get("bucket")->Option.flatMap(JSON.Decode.string),
      obj->Dict.get("prefix")->Option.flatMap(JSON.Decode.string),
    ) {
    | (Some(bucket), Some(prefix)) => Some({bucket, prefix})
    | _ => None
    }
  | _ => None
  }

let loadStores = (): dict<storeConfig> =>
  switch getEnv("UPLOAD_STORES")->Option.map(s => JSON.parseOrThrow(s)) {
  | Some(Object(obj)) =>
    obj
    ->Dict.toArray
    ->Array.filterMap(((k, v)) => decodeStore(v)->Option.map(c => (k, c)))
    ->Dict.fromArray
  | _ => Dict.make()
  }

// Release window: an object is releasable only while younger than this. A policy,
// not a guarantee (see the plan); defaults to 15 minutes.
let windowMs = (): float =>
  getEnv("RELEASE_WINDOW_SECONDS")
  ->Option.flatMap(Float.fromString)
  ->Option.getOr(900.)
  ->(s => s *. 1000.)

// ── The release rule, as a pure decision ────────────────────────────────────
//
// Split from S3 so it is testable without a running store (the plan's Step 4):
// `scopeCheck` and `ageOk` are the string- and clock-checkable halves, and
// `decideRelease` composes them. The handler runs `scopeCheck` first so it never
// heads a key that is not the caller's, then heads for `LastModified` and applies
// `decideRelease` as the single source of truth.

type releaseOutcome = Released | Refused(string)

// Key must sit under this store's served prefix (`not_in_store`) and under the
// caller's own identity segment within it (`not_yours`); an empty `sub` is
// `unauthenticated` (the authorizer should have refused first — this is a guard).
let scopeCheck = (~key: string, ~sub: string, ~servedPrefix: string): result<unit, string> =>
  if sub == "" {
    Error("unauthenticated")
  } else if !(key->String.startsWith(`${servedPrefix}/`)) {
    Error("not_in_store")
  } else if !(key->String.startsWith(`${servedPrefix}/${sub}/`)) {
    Error("not_yours")
  } else {
    Ok()
  }

// `None` (object absent) passes: release is idempotent, so deleting what is already
// gone is success. A present object passes only inside the window.
let ageOk = (~lastModifiedMs: option<float>, ~nowMs: float, ~windowMs: float): bool =>
  switch lastModifiedMs {
  | None => true
  | Some(lm) => nowMs -. lm <= windowMs
  }

let decideRelease = (
  ~key: string,
  ~sub: string,
  ~servedPrefix: string,
  ~lastModifiedMs: option<float>,
  ~nowMs: float,
  ~windowMs: float,
): releaseOutcome =>
  switch scopeCheck(~key, ~sub, ~servedPrefix) {
  | Error(reason) => Refused(reason)
  | Ok() => ageOk(~lastModifiedMs, ~nowMs, ~windowMs) ? Released : Refused("too_old")
  }

// ── AppSync resolver event / result shapes ──────────────────────────────────

type identity = {sub?: string}
type uploadArgs = {
  store?: string,
  fileName?: string,
  contentType?: string,
  storageRef?: string,
}
type appSyncEvent = {
  operation?: string,
  arguments?: uploadArgs,
  identity?: identity,
}

let ticket = (~uploadUrl: string, ~storageRef: string): JSON.t =>
  Dict.fromArray([
    ("uploadUrl", JSON.Encode.string(uploadUrl)),
    ("storageRef", JSON.Encode.string(storageRef)),
  ])->JSON.Encode.object

let releaseResult = (~released: bool, ~reason: option<string>): JSON.t =>
  Dict.fromArray([
    ("released", JSON.Encode.bool(released)),
    ("reason", reason->Option.mapOr(JSON.Null, JSON.Encode.string)),
  ])->JSON.Encode.object

// Strip the leading `/` a `storageRef` carries (`/{prefix}/{key}`) to recover the
// S3 object key.
let keyOfRef = (storageRef: string): string =>
  storageRef->String.startsWith("/")
    ? storageRef->String.slice(~start=1, ~end=storageRef->String.length)
    : storageRef

// Head for `LastModified`, mapping a missing object (404) to `None` so the caller
// can treat it as the idempotent case. Any other S3 error propagates — a release
// must not report success when it could not even read the object's age.
let headLastModifiedMs = async (~client: s3Client, ~bucket: string, ~key: string): option<float> =>
  try {
    let out = await sendHead(client, makeHeadObjectCommand({bucket, key}))
    out.lastModified->Option.map(d => d->Date.getTime)
  } catch {
  | exn =>
    switch exn->JsExn.fromException->Option.flatMap(JsExn.name) {
    | Some("NotFound") | Some("NoSuchKey") => None
    | _ => throw(exn)
    }
  }

// ── Operations ──────────────────────────────────────────────────────────────

let handlePresign = async (
  ~client: s3Client,
  ~bucket: string,
  ~servedPrefix: string,
  ~sub: string,
  ~args: uploadArgs,
): JSON.t => {
  if sub == "" {
    JsError.throwWithMessage("unauthenticated")
  }
  let fileName = args.fileName->Option.getOr("upload")
  // The object key doubles as the served path segment: rooted at the store's
  // served prefix so the CloudFront `{prefix}/*` behavior fronts it, and namespaced
  // by the verified `sub` so the release rule can tell one caller's objects apart.
  let key = `${servedPrefix}/${sub}/${NodeCrypto.randomUUID()}/${fileName}`
  let command = makePutObjectCommand({bucket, key, contentType: ?args.contentType})
  let uploadUrl = await getSignedUrl(client, command, {expiresIn: 300})
  // Same-origin relative ref `/{key}`: the served bucket is fronted read-only by the
  // UI's own CloudFront distribution under `{prefix}/*`, so a command stores this
  // directly-renderable value. See [docs/plans/done/served-buckets.md].
  ticket(~uploadUrl, ~storageRef=`/${key}`)
}

let handleRelease = async (
  ~client: s3Client,
  ~bucket: string,
  ~servedPrefix: string,
  ~sub: string,
  ~args: uploadArgs,
): JSON.t => {
  let key = args.storageRef->Option.getOr("")->keyOfRef
  switch scopeCheck(~key, ~sub, ~servedPrefix) {
  | Error(reason) => releaseResult(~released=false, ~reason=Some(reason))
  | Ok() =>
    let lastModifiedMs = await headLastModifiedMs(~client, ~bucket, ~key)
    switch decideRelease(
      ~key,
      ~sub,
      ~servedPrefix,
      ~lastModifiedMs,
      ~nowMs=Date.now(),
      ~windowMs=windowMs(),
    ) {
    | Released =>
      // Idempotent: DeleteObject succeeds whether or not the key exists.
      let _ = await sendDelete(client, makeDeleteObjectCommand({bucket, key}))
      releaseResult(~released=true, ~reason=None)
    | Refused(reason) => releaseResult(~released=false, ~reason=Some(reason))
    }
  }
}

// ── Runtime handler ─────────────────────────────────────────────────────────

let handler = async (event: appSyncEvent): JSON.t => {
  let stores = loadStores()
  let args = event.arguments->Option.getOr({})
  let sub = event.identity->Option.flatMap(i => i.sub)->Option.getOr("")
  let storeKey = args.store->Option.getOr("")
  switch stores->Dict.get(storeKey) {
  | None => JsError.throwWithMessage("unknown_store")
  | Some({bucket, prefix}) =>
    let client = makeS3Client()
    switch event.operation->Option.getOr("presign") {
    | "release" => await handleRelease(~client, ~bucket, ~servedPrefix=prefix, ~sub, ~args)
    | _ => await handlePresign(~client, ~bucket, ~servedPrefix=prefix, ~sub, ~args)
    }
  }
}
