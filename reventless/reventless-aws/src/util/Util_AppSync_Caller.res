// IAM-signed AppSync HTTP mutation sender for deploy-time dispatch.
//
// Uses @smithy/signature-v4 + @aws-sdk/credential-provider-node to sign
// requests with the ambient AWS credentials available in the Pulumi deploy
// process (developer machine, CI role, or EC2/ECS instance profile).
//
// The signed request is sent via the Node 18+ global fetch.
// Arguments are serialised as inline GraphQL literals — no variable-type
// declarations required, so any mutation can be called generically.

// ── AWS credential provider ────────────────────────────────────────────────

type awsCredentials = {
  accessKeyId: string,
  secretAccessKey: string,
  sessionToken?: string,
}

// defaultProvider() returns a credential-provider function.
// It resolves credentials from env vars → SSO → ini files → IMDSv2.
@module("@aws-sdk/credential-provider-node")
external defaultProvider: unit => (unit => promise<awsCredentials>) = "defaultProvider"

// ── SigV4 signer ──────────────────────────────────────────────────────────────

// Hash constructor type used as sha256 option for SignatureV4
type hashCtor

// Hash class from @smithy/hash-node; used as Hash.bind(null, "sha256")
@module("@smithy/hash-node") external _hashClass: hashCtor = "Hash"

// Hash.bind(null, "sha256") yields a zero-argument constructor that
// SignatureV4 calls internally to create SHA-256 hash instances.
@send external bindCtor: (hashCtor, @as(json`null`) _, string) => hashCtor = "bind"
let sha256: hashCtor = _hashClass->bindCtor("sha256")

type signerOptions = {
  service: string,
  region: string,
  credentials: unit => promise<awsCredentials>,
  sha256: hashCtor,
}

type httpHeaders = dict<string>

type httpRequest = {
  method: string,
  hostname: string,
  path: string,
  headers: httpHeaders,
  body: string,
}

type signer

@module("@smithy/signature-v4") @new
external makeSigner: signerOptions => signer = "SignatureV4"

@send external signRequest: (signer, httpRequest) => promise<httpRequest> = "sign"

// ── Node 18+ global fetch ──────────────────────────────────────────────────

type fetchInit = {
  method: string,
  headers: httpHeaders,
  body: string,
}

@val external fetch: (string, fetchInit) => promise<{..}> = "fetch"
@send external responseJson: {..} => promise<JSON.t> = "json"

// ── URL parser ─────────────────────────────────────────────────────────────

@new external parseUrl: string => {..} = "URL"

// ── GraphQL inline-arg serialiser ──────────────────────────────────────────
//
// Converts a JSON.t value to a GraphQL literal string.
// GraphQL accepts the same literals as JSON for scalars and arrays;
// input-object fields use unquoted keys (same as JS object shorthand).
// This lets us call any mutation without declaring variable types.

let rec jsonToLiteral = (value: JSON.t): string =>
  switch value {
  | String(s) =>
    let escaped = s->String.replaceAll("\\", "\\\\")->String.replaceAll("\"", "\\\"")
    `"${escaped}"`
  | Boolean(b) => b ? "true" : "false"
  | Number(n) => n->Float.toString
  | Null => "null"
  | Array(arr) => `[${arr->Array.map(jsonToLiteral)->Array.join(", ")}]`
  | Object(obj) =>
    let pairs = obj->Dict.toArray->Array.map(((k, v)) => `${k}: ${jsonToLiteral(v)}`)
    `{${pairs->Array.join(", ")}}`
  }

let buildQuery = (~mutation: string, ~variablesDict: dict<JSON.t>): string => {
  let args =
    variablesDict
    ->Dict.toArray
    ->Array.map(((k, v)) => `${k}: ${jsonToLiteral(v)}`)
    ->Array.join(", ")
  `mutation { ${mutation}(${args}) }`
}

// ── sendMutation ────────────────────────────────────────────────────────────
//
// Signs and sends a single GraphQL mutation to an AppSync endpoint via IAM.
// ~variables accepts any value; undefined/optional fields are omitted by
// JSON.stringifyAny (mirrors how JSON.stringify drops undefined object keys).
// Returns a promise — callers fire-and-forget with `let _ = sendMutation(...)`.

// Signs and sends a GraphQL query; returns the `data` object or None on error.
// ~queryString must be a complete "query { field(...) { ... } }" string.
let sendQuery = async (~endpoint: string, ~region: string, ~queryString: string): option<JSON.t> => {
  let url = parseUrl(endpoint)
  let hostname: string = (url)["hostname"]
  let path: string = (url)["pathname"]

  let body =
    Dict.fromArray([("query", queryString->JSON.Encode.string)])
    ->JSON.Encode.object
    ->JSON.stringify

  let credProvider = defaultProvider()
  let signer = makeSigner({
    service: "appsync",
    region,
    credentials: credProvider,
    sha256,
  })

  let headers: dict<string> = Dict.fromArray([
    ("content-type", "application/json"),
    ("host", hostname),
  ])

  let request: httpRequest = {method: "POST", hostname, path, headers, body}
  let signed = await signer->signRequest(request)
  let response = await fetch(endpoint, {method: "POST", headers: signed.headers, body: signed.body})
  let json = await response->responseJson
  switch json->JSON.Decode.object {
  | Some(d) =>
    switch d->Dict.get("errors") {
    | Some(errors) =>
      Console.error(`[Util_AppSync_Caller] query errors: ${errors->JSON.stringify}`)
      None
    | None => d->Dict.get("data")
    }
  | None => None
  }
}

let sendMutation = async (~endpoint: string, ~region: string, ~mutation: string, ~variables: 'a) => {
  let url = parseUrl(endpoint)
  let hostname: string = (url)["hostname"]
  let path: string = (url)["pathname"]

  // Normalise variables to a JSON.t dict (strips undefined optional fields)
  let variablesDict: dict<JSON.t> =
    switch variables->JSON.stringifyAny {
    | Some(str) =>
      switch str->JSON.parseOrThrow {
      | Object(d) => d
      | _ => Dict.make()
      }
    | None => Dict.make()
    }

  let query = buildQuery(~mutation, ~variablesDict)
  let body =
    Dict.fromArray([("query", query->JSON.Encode.string)])
    ->JSON.Encode.object
    ->JSON.stringify

  let credProvider = defaultProvider()
  let signer = makeSigner({
    service: "appsync",
    region,
    credentials: credProvider,
    sha256,
  })

  let headers: dict<string> = Dict.fromArray([
    ("content-type", "application/json"),
    ("host", hostname),
  ])

  let request: httpRequest = {method: "POST", hostname, path, headers, body}
  let signed = await signer->signRequest(request)

  let response = await fetch(endpoint, {method: "POST", headers: signed.headers, body: signed.body})

  let json = await response->responseJson
  switch json->JSON.Decode.object->Option.flatMap(d => d->Dict.get("errors")) {
  | Some(errors) =>
    Console.error(`[Util_AppSync_Caller] ${mutation} errors: ${errors->JSON.stringify}`)
  | None => ()
  }
}
