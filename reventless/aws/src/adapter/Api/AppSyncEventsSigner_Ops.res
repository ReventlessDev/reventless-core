// Shared SigV4 signer + AppSync Events publisher for the two stream-relay
// Lambdas (EventLogSubscription, StateTopic). Both sign a `POST /event` to the
// AppSync Events HTTP API with the ambient Lambda execution-role credentials and
// publish onto a channel.
//
// Runtime-pure and dependency-free by design: the signing is hand-rolled on
// `node:crypto` (always present, no SDK) rather than @smithy/signature-v4 — so
// the Lambda cold-start graph carries NO AWS SDK and cannot hit the SDK-version
// skew ("Frankenstein SDK") class of failure. This is a faithful port of the
// former inline JS `signedHeaders` the two handler strings duplicated verbatim;
// AppSyncEventsSigner_ParityFixture.mjs pins that original as a golden reference
// and AppSyncEventsSigner_OpsTest asserts byte-for-byte equality.

let sha256hex = (data: string): string =>
  NodeCrypto.createHash("sha256")->NodeCrypto.hashUpdate(data)->NodeCrypto.hashDigest("hex")

let hmacFromStr = (key: string, data: string): NodeCrypto.buffer =>
  NodeCrypto.createHmac("sha256", key)->NodeCrypto.hmacUpdate(data)->NodeCrypto.hmacDigestBuffer
let hmacFromBuf = (key: NodeCrypto.buffer, data: string): NodeCrypto.buffer =>
  NodeCrypto.createHmacFromBuffer("sha256", key)->NodeCrypto.hmacUpdate(data)->NodeCrypto.hmacDigestBuffer

// ── SigV4 ───────────────────────────────────────────────────────────────────

type creds = {accessKeyId: string, secretAccessKey: string, sessionToken: option<string>}

// Ambient Lambda execution-role credentials (the managed runtime injects these).
let envCreds = (): creds => {
  accessKeyId: NodeProcess.env->Dict.get("AWS_ACCESS_KEY_ID")->Option.getOr(""),
  secretAccessKey: NodeProcess.env->Dict.get("AWS_SECRET_ACCESS_KEY")->Option.getOr(""),
  sessionToken: NodeProcess.env->Dict.get("AWS_SESSION_TOKEN"),
}

let region = (): string => NodeProcess.env->Dict.get("AWS_REGION")->Option.getOr("eu-west-1")

// Sign a `POST <path>` for service `appsync`. `isoNow` is a Date().toISOString()
// string, taken as an argument so the signer is pure and parity-testable. The
// amzDate / dateStamp are derived by fixed slicing of the ISO-8601 layout
// ("YYYY-MM-DDTHH:MM:SS.sssZ") — equivalent to the former regex strip, without
// the regex. Returns the headers (host, x-amz-date, [security-token],
// Authorization) to merge into the request.
let signedHeaders = (
  ~host: string,
  ~path: string,
  ~body: string,
  ~region: string,
  ~isoNow: string,
  ~creds: creds,
): dict<string> => {
  let sl = (a, b) => isoNow->String.slice(~start=a, ~end=b)
  let dateStamp = sl(0, 4) ++ sl(5, 7) ++ sl(8, 10)
  let amzDate = dateStamp ++ "T" ++ sl(11, 13) ++ sl(14, 16) ++ sl(17, 19) ++ "Z"

  let baseHeaders = [("host", host), ("x-amz-date", amzDate)]
  let headers = switch creds.sessionToken {
  | Some(token) if token != "" => baseHeaders->Array.concat([("x-amz-security-token", token)])
  | _ => baseHeaders
  }
  // Codepoint sort matches both the JS `localeCompare` (canonical headers) and
  // the default `.sort()` (signed-headers list) for these lowercase-ASCII keys.
  let sorted = headers->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
  let canonicalHeaders = sorted->Array.map(((k, v)) => `${k}:${v}\n`)->Array.join("")
  let signedHeaderList = sorted->Array.map(((k, _)) => k)->Array.join(";")

  let canonicalRequest =
    ["POST", path, "", canonicalHeaders, signedHeaderList, sha256hex(body)]->Array.join("\n")
  let scope = `${dateStamp}/${region}/appsync/aws4_request`
  let stringToSign =
    ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(canonicalRequest)]->Array.join("\n")

  let kDate = hmacFromStr("AWS4" ++ creds.secretAccessKey, dateStamp)
  let kRegion = hmacFromBuf(kDate, region)
  let kService = hmacFromBuf(kRegion, "appsync")
  let kSigning = hmacFromBuf(kService, "aws4_request")
  let signature = NodeCrypto.createHmacFromBuffer("sha256", kSigning)->NodeCrypto.hmacUpdate(stringToSign)->NodeCrypto.hmacDigest("hex")

  let authorization = `AWS4-HMAC-SHA256 Credential=${creds.accessKeyId}/${scope}, SignedHeaders=${signedHeaderList}, Signature=${signature}`
  let out = Dict.fromArray(sorted)
  out->Dict.set("Authorization", authorization)
  out
}

// ── AppSync Events publish (Node 18+ global fetch) ──────────────────────────

type url
@new external parseUrl: string => url = "URL"
@get external urlHostname: url => string = "hostname"

type fetchInit = {method: string, headers: dict<string>, body: string}
type fetchResponse
@val external fetch: (string, fetchInit) => promise<fetchResponse> = "fetch"
@get external responseOk: fetchResponse => bool = "ok"
@get external responseStatus: fetchResponse => int = "status"
@send external responseText: fetchResponse => promise<string> = "text"

// Sign and POST one AppSync Events request body to `<endpoint>/event`. The
// caller builds `body` (channel + events) and inspects the response; error
// handling differs per handler (log-and-continue vs. transient/permanent split).
let postEvent = async (
  ~endpoint: string,
  ~region: string,
  ~isoNow: string,
  ~creds: creds,
  ~body: string,
): fetchResponse => {
  let host = parseUrl(endpoint)->urlHostname
  let auth = signedHeaders(~host, ~path="/event", ~body, ~region, ~isoNow, ~creds)
  let headers = Dict.fromArray([
    ("accept", "application/json, text/javascript"),
    ("content-encoding", "amz-1.0"),
    ("content-type", "application/json; charset=UTF-8"),
  ])
  auth->Dict.forEachWithKey((v, k) => headers->Dict.set(k, v))
  await fetch(`${endpoint}/event`, {method: "POST", headers, body})
}

// AppSync Events channel segments allow only [A-Za-z0-9-]; anything else
// collapses to `-`. Mirrors the UI's AutoLive.normalizeSegment.
let pathSegment = (value: string): string =>
  value->String.replaceRegExp(%re("/[^A-Za-z0-9-]/g"), "-")
