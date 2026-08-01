// Runtime handler for the upload presign service — compiled, type-checked, and
// Pulumi-free so it can be shipped as an EntryPoint module (`Upload_Presign_S3`
// bundles it and re-exports `handler` from the code archive). Keeping it out of
// the deploy-time module is what avoids both the serialized-closure SDK skew and
// the deploy-time Pulumi import leaking into the Lambda's cold-start graph.
//
// Reads a JSON body `{fileName, contentType}`, derives a target key
// `uploads/<identity?>/<uuid>/<fileName>`, presigns a PUT to `UPLOAD_BUCKET`
// (expires in 300s), and returns `{uploadUrl, storageRef}`. A Bearer token, when
// present, is decoded (no signature verification here — the auth layer verifies;
// here we only namespace the storage key) and its `sub` namespaces the key.

// ── AWS SDK v3 bindings ─────────────────────────────────────────────────────

type s3Client

type putObjectInput = {
  @as("Bucket") bucket: string,
  @as("Key") key: string,
  @as("ContentType") contentType?: string,
}
type putObjectCommand

@module("@aws-sdk/client-s3") @new external makeS3Client: unit => s3Client = "S3Client"

@module("@aws-sdk/client-s3") @new
external makePutObjectCommand: putObjectInput => putObjectCommand = "PutObjectCommand"

type presignOptions = {expiresIn: int}

@module("@aws-sdk/s3-request-presigner")
external getSignedUrl: (s3Client, putObjectCommand, presignOptions) => promise<string> =
  "getSignedUrl"

// ── Node bindings (replacing the former `%raw` helpers with typed externals) ──


type buffer
@val @scope("Buffer") external bufferFromBase64: (string, string) => buffer = "from"
@send external bufferToString: (buffer, string) => string = "toString"

// Read an env var, mapping "" / unset to None.
let getEnv = (k: string): option<string> =>
  switch NodeProcess.env->Dict.get(k) {
  | Some("") | None => None
  | Some(v) => Some(v)
  }

// ── Function URL event / response shapes (payload format 2.0) ────────────────

type functionUrlEvent = {
  body?: string,
  headers?: dict<string>,
}

type response = {
  statusCode: int,
  headers?: dict<string>,
  body: string,
}

// CORS belongs to the Function URL's own `cors` configuration and to nothing
// else. AWS injects the allow-origin header itself whenever the request carries
// an `Origin`, so a handler that also sets one sends the header *twice* — and a
// browser rejects `Access-Control-Allow-Origin: *, *` outright, failing every
// cross-origin call while leaving `curl` (which sends no `Origin`, so AWS adds
// nothing) working perfectly.
//
// It is also the only way `~corsOrigins` can mean anything: a hardcoded `*`
// here would keep answering `*` for a deployment that narrowed the allow-list.
let jsonHeaders = () => Dict.fromArray([("content-type", "application/json")])

// Decode a JWT payload's `sub` claim without verifying the signature.
let decodeJwtSub = (header: string): option<string> =>
  try {
    let token =
      header->String.startsWith("Bearer ")
        ? header->String.slice(~start=7, ~end=header->String.length)
        : header
    switch token->String.split(".")->Array.get(1) {
    | Some(payload) =>
      let base64 = payload->String.replaceAll("-", "+")->String.replaceAll("_", "/")
      switch JSON.parseOrThrow(bufferFromBase64(base64, "base64")->bufferToString("utf8")) {
      | Object(obj) => obj->Dict.get("sub")->Option.flatMap(JSON.Decode.string)
      | _ => None
      }
    | None => None
    }
  } catch {
  | _ => None
  }

// Key prefix from the caller identity when a Bearer token is present.
let identityPrefix = (event: functionUrlEvent): string => {
  let authHeader =
    event.headers->Option.flatMap(h =>
      h->Dict.get("authorization")->Option.orElse(h->Dict.get("Authorization"))
    )
  switch authHeader->Option.flatMap(decodeJwtSub) {
  | Some(sub) => `${sub}/`
  | None => ""
  }
}

// ── Runtime handler ─────────────────────────────────────────────────────────

let handler = async (event: functionUrlEvent): response => {
  try {
    let bucket = getEnv("UPLOAD_BUCKET")->Option.getOr("")
    let parsed =
      event.body
      ->Option.getOr("{}")
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.getOr(Dict.make())
    let fileName =
      parsed->Dict.get("fileName")->Option.flatMap(JSON.Decode.string)->Option.getOr("upload")
    let contentType = parsed->Dict.get("contentType")->Option.flatMap(JSON.Decode.string)

    // The object key doubles as the served path segment: it is rooted at the
    // served prefix (`SERVED_PREFIX`, e.g. `uploads`) so the CloudFront
    // `{prefix}/*` behavior fronts it. Callers PUT to this exact key.
    let servedPrefix = getEnv("SERVED_PREFIX")->Option.getOr("uploads")
    let key = `${servedPrefix}/${identityPrefix(event)}${NodeCrypto.randomUUID()}/${fileName}`
    let client = makeS3Client()
    let command = makePutObjectCommand({bucket, key, contentType: ?contentType})
    let uploadUrl = await getSignedUrl(client, command, {expiresIn: 300})

    // The stored ref is a same-origin relative URL `/{key}`: the served bucket is
    // fronted read-only by the UI's own CloudFront distribution under
    // `{prefix}/*`, so a command stores this directly-renderable value and an
    // `image`-semantic field thumbnails it with no post-processing and no public
    // bucket. See [docs/plans/done/ui-served-buckets.md].
    let storageRef = `/${key}`

    {
      statusCode: 200,
      headers: jsonHeaders(),
      body: Dict.fromArray([
        ("uploadUrl", JSON.Encode.string(uploadUrl)),
        ("storageRef", JSON.Encode.string(storageRef)),
      ])
      ->JSON.Encode.object
      ->JSON.stringify,
    }
  } catch {
  | exn =>
    Console.error2("UploadPresign: presign failed", exn)
    {
      statusCode: 400,
      headers: jsonHeaders(),
      body: Dict.fromArray([("error", JSON.Encode.string("presign_failed"))])
      ->JSON.Encode.object
      ->JSON.stringify,
    }
  }
}
