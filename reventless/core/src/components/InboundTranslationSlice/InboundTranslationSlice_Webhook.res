// The HTTP door of an inbound translation slice: find the slice a request's path
// names, check its signature over the raw body, and hand the parsed body to
// `receive` as the caller the endpoint stands for. Runtime-pure — the AWS command
// Lambda and the local registry both serve through it.

type request = {
  method: string,
  path: string,
  /** Header names lower-cased. */
  headers: dict<string>,
  /** The body exactly as sent: a signature is over these bytes, not over a re-encoding. */
  body: string,
}

type response = {status: int, body: string}

/** An endpoint with its slice's role erased to a role name. */
type route = {
  slice: string,
  path: string,
  method: string,
  auth: Reventless.InboundTranslationSlice.webhookAuth,
  roles: array<Reventless.Role.name>,
}

/** A route and the slice operations that serve it. `receive` is the webhook door's. */
type slice = {
  route: route,
  receive: (
    JSON.t,
    ~caller: Reventless.Identity.t,
  ) => promise<ReventlessInfra.InboundTranslationSlice.receiveResult>,
  refuse: (
    ~body: string,
    ~errorCode: string,
    string,
  ) => promise<ReventlessInfra.InboundTranslationSlice.receiveResult>,
}

let normalizePath = (path: string): string =>
  path->String.split("/")->Array.filter(segment => segment != "")->Array.join("/")

let routeOf = (
  ~slice: string,
  endpoint: Reventless.InboundTranslationSlice.endpointConfig<'role>,
): route => {
  slice,
  path: normalizePath(endpoint.path),
  method: (endpoint.method->Option.getOr(Post) :> string),
  auth: endpoint.auth,
  roles: switch endpoint.role {
  | Some(role) =>
    Reventless.Authorization.AllowRoles([role])
    ->Reventless.Authorization.named
    ->Reventless.Authorization.rolesOf
  | None => []
  },
}

/** The environment variable a named secret is read from. */
let secretEnvKey = (name: string): string =>
  "REVENTLESS_WEBHOOK_SECRET_" ++ name->String.toUpperCase->String.replaceRegExp(/[^A-Z0-9]/g, "_")

/** The secrets a variable holds: several, comma-separated, while one is rotated. */
let secretsOf = (raw: string): array<string> =>
  raw->String.split(",")->Array.map(String.trim)->Array.filter(secret => secret != "")

@val external env: dict<string> = "process.env"

let secretFromEnv = (name: string): option<string> => env->Dict.get(secretEnvKey(name))

// Compares every character whatever the first difference, so the time taken does
// not tell a forger how much of a guess was right.
let sameText = (a: string, b: string): bool => {
  let code = (text, i) => text->String.charCodeAt(i)->Option.getOr(0)
  a->String.length == b->String.length && {
      let diff = ref(0)
      for i in 0 to a->String.length - 1 {
        diff := diff.contents->Int.bitwiseOr(code(a, i)->Int.bitwiseXor(code(b, i)))
      }
      diff.contents == 0
    }
}

let hmacHex = (~secret: string, text: string): string =>
  NodeCrypto.createHmac("sha256", secret)->NodeCrypto.hmacUpdate(text)->NodeCrypto.hmacDigest("hex")

/** Whether `body` carries a valid signature by one of `secrets`. */
let verify = (
  signature: Reventless.InboundTranslationSlice.signature,
  ~secrets: array<string>,
  ~headers: dict<string>,
  ~body: string,
  ~nowSeconds: float,
): result<unit, string> => {
  let header = name => headers->Dict.get(name->String.toLowerCase)
  let given = switch (header(signature.header), signature.prefix) {
  | (None, _) => Error(`missing ${signature.header} header`)
  | (Some(raw), None) => Ok(raw)
  | (Some(raw), Some(prefix)) if raw->String.startsWith(prefix) =>
    Ok(raw->String.slice(~start=prefix->String.length))
  | (Some(_), Some(prefix)) => Error(`${signature.header} does not start with "${prefix}"`)
  }
  let signed = switch signature.timestampHeader {
  | None => Ok(body)
  | Some(name) =>
    switch header(name) {
    | None => Error(`missing ${name} header`)
    | Some(raw) =>
      switch raw->Float.fromString {
      | None => Error(`${name} is not a time in seconds`)
      | Some(at)
        if Math.abs(nowSeconds -. at) >
        signature.toleranceSeconds->Option.getOr(300)->Int.toFloat =>
        Error(`${name} is outside the accepted window`)
      | Some(_) => Ok(`${raw}.${body}`)
      }
    }
  }
  switch (given, signed) {
  | (Error(msg), _) | (_, Error(msg)) => Error(msg)
  | (Ok(given), Ok(text)) =>
    let given = given->String.trim->String.toLowerCase
    secrets->Array.some(secret => sameText(hmacHex(~secret, text), given))
      ? Ok()
      : Error(`${signature.header} does not match the body`)
  }
}

/** Who a request that passed `route.auth` acts as. An open URL identifies nobody. */
let callerOf = (route: route, ~signed: bool): Reventless.Identity.t =>
  signed
    ? {
        userId: `webhook:${route.slice}`,
        username: route.slice,
        groups: route.roles->Array.map(Reventless.Role.groupOf),
        provider: Custom("webhook"),
      }
    : Reventless.Identity.anonymous

let json = (fields: array<(string, JSON.t)>): string =>
  fields->Dict.fromArray->JSON.Encode.object->JSON.stringify

let plain = (status, error) => {status, body: json([("error", JSON.Encode.string(error))])}

/** The status a sender acts on: 2xx done, 5xx try again, any other 4xx do not. */
let statusOf = (result: ReventlessInfra.InboundTranslationSlice.receiveResult): int =>
  switch result {
  | Ok(_) => 200
  | Error({errorCode: "Unsigned"}) => 401
  | Error({errorCode: "InvalidBody"}) => 400
  | Error({errorCode: "Forbidden"}) => 403
  | Error({errorCode: "PublishFailed"}) => 503
  | Error(_) => 422
  }

let respond = (result: ReventlessInfra.InboundTranslationSlice.receiveResult): response => {
  status: statusOf(result),
  body: switch result {
  | Ok({requestId, commandCount}) =>
    json([
      ("requestId", JSON.Encode.string(requestId)),
      ("commandCount", JSON.Encode.int(commandCount)),
    ])
  | Error({requestId, error}) =>
    json([("requestId", JSON.Encode.string(requestId)), ("error", JSON.Encode.string(error))])
  },
}

/** Serve one request on its slice. A secret the platform does not have is a
    misconfiguration, answered 500 and logged, never treated as open. */
let serve = async (
  slice: slice,
  ~secretOf: string => option<string>=secretFromEnv,
  ~nowSeconds: float=Date.now() /. 1000.,
  request: request,
): response =>
  if request.method->String.toUpperCase != slice.route.method {
    plain(405, `${slice.route.path} accepts ${slice.route.method}`)
  } else {
    let signed = switch slice.route.auth {
    | Open => Ok(Ok(false))
    | SignedBody(signature) =>
      switch secretOf(signature.secret)->Option.mapOr([], secretsOf) {
      | [] => Error(secretEnvKey(signature.secret))
      | secrets =>
        Ok(
          verify(
            signature,
            ~secrets,
            ~headers=request.headers,
            ~body=request.body,
            ~nowSeconds,
          )->Result.map(() => true),
        )
      }
    }
    switch signed {
    | Error(key) =>
      EffectLogger.logError(
        ~comp=`InboundTranslationSlice(${slice.route.slice})`,
        `webhook secret ${key} is not set; refusing every request`,
      )->Effect.runSync
      plain(500, "webhook is not configured")
    | Ok(Error(msg)) => respond(await slice.refuse(~body=request.body, ~errorCode="Unsigned", msg))
    | Ok(Ok(signed)) =>
      switch try Some(JSON.parseOrThrow(request.body)) catch {
      | _ => None
      } {
      | None =>
        respond(
          await slice.refuse(~body=request.body, ~errorCode="InvalidBody", "body is not JSON"),
        )
      | Some(input) => respond(await slice.receive(input, ~caller=callerOf(slice.route, ~signed)))
      }
    }
  }

/** Serve a request on whichever slice its path names. */
let dispatch = async (
  slices: array<slice>,
  ~secretOf=?,
  ~nowSeconds=?,
  request: request,
): response => {
  let path = normalizePath(request.path)
  switch slices->Array.find(slice => slice.route.path == path) {
  | Some(slice) => await serve(slice, ~secretOf?, ~nowSeconds?, request)
  | None => plain(404, `no webhook at /${path}`)
  }
}
