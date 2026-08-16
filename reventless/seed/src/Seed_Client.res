// GraphQL transport for seeding: authentication, mutation dispatch, and the
// query helpers a seed run needs to observe what it produced.
//
// Everything here is domain-agnostic — it knows about the shapes the framework
// generates (the CommandResult union, Relay-style connections) but nothing about
// any particular plugin.

open Seed_Types

// ── Node 18+ globals ────────────────────────────────────────────────────────

type fetchInit = {method: string, headers: dict<string>, body: string}
type response

@val external fetch: (string, fetchInit) => promise<response> = "fetch"
@send external responseJson: response => promise<JSON.t> = "json"
@send external responseText: response => promise<string> = "text"
@get external responseOk: response => bool = "ok"
@get external responseStatus: response => int = "status"

@val external setTimeout: (unit => unit, int) => unit = "setTimeout"
@scope("Date") @val external nowMs: unit => float = "now"

let sleep = (ms: int): promise<unit> => Promise.make((resolve, _) => setTimeout(() => resolve(), ms))

// ── Configuration ───────────────────────────────────────────────────────────

type config = {
  endpoint: string,
  // Present only for the `login` flow (a platform that mints tokens over HTTP,
  // e.g. the local dev `/__inmemory/login`). Omit when the bearer is supplied
  // out-of-band via `useToken` (e.g. a Cognito id token minted by the caller).
  loginEndpoint?: string,
  username?: string,
  password?: string,
}

type t = {config: config, mutable token: option<string>}

let make = (~config: config): t => {config, token: None}

/** The bearer token from the last successful `login`, if any — so callers (e.g.
    Seed.Upload) can authenticate side-channel requests with the same identity. */
let currentToken = (t: t): option<string> => t.token

/** The GraphQL endpoint this client targets — so `Seed.Upload` can resolve a
    relative presigned `uploadUrl` against the same origin. */
let endpoint = (t: t): string => t.config.endpoint

/** Injects a bearer obtained out-of-band (e.g. a Cognito id token), instead of
    minting one via `login`. Provider-agnostic: the harness only cares that the
    token is a valid bearer for `endpoint`. */
let useToken = (t: t, token: string): unit => t.token = Some(token)

// ── JSON helpers ────────────────────────────────────────────────────────────

let field = (json: JSON.t, key: string): option<JSON.t> =>
  switch json {
  | Object(obj) => obj->Dict.get(key)
  | _ => None
  }

let asString = (json: JSON.t): option<string> =>
  switch json {
  | String(s) => Some(s)
  | _ => None
  }

/** Reads a string property off a node returned by `queryAllNodes`. */
let nodeString = (node: JSON.t, key: string): option<string> =>
  node->field(key)->Option.flatMap(asString)

// ── Requests ────────────────────────────────────────────────────────────────

let login = async (t: t): unit => {
  let loginEndpoint = switch t.config.loginEndpoint {
  | Some(e) => e
  | None => throw(Failed("login: no loginEndpoint configured — supply one or call useToken"))
  }
  let username = t.config.username->Option.getOr("")
  let password = t.config.password->Option.getOr("")
  let body = JSON.stringify(
    JSON.Encode.object(
      Dict.fromArray([
        ("username", JSON.Encode.string(username)),
        ("password", JSON.Encode.string(password)),
      ]),
    ),
  )
  let res = try await fetch(
    loginEndpoint,
    {method: "POST", headers: Dict.fromArray([("content-type", "application/json")]), body},
  ) catch {
  | _ => throw(Failed(`login: cannot reach ${loginEndpoint} — is the platform running?`))
  }
  if !(res->responseOk) {
    let detail = await res->responseText
    throw(
      Failed(
        `login as "${username}" failed with HTTP ${(res->responseStatus)
            ->Int.toString}: ${detail}`,
      ),
    )
  }
  let json = await res->responseJson
  t.token = json->field("token")->Option.flatMap(asString)
}

/**
 * Sends one GraphQL document and returns its `data`. A GraphQL-level error
 * aborts the run: a half-seeded store is worse than an empty one, because it
 * looks like a working dataset.
 */
let gql = async (t: t, ~query: string, ~label: string): JSON.t => {
  let headers = Dict.fromArray([("content-type", "application/json")])
  switch t.token {
  | Some(token) => headers->Dict.set("authorization", `Bearer ${token}`)
  | None => ()
  }
  let body = JSON.stringify(
    JSON.Encode.object(Dict.fromArray([("query", JSON.Encode.string(query))])),
  )
  let res = try await fetch(t.config.endpoint, {method: "POST", headers, body}) catch {
  | _ =>
    throw(Failed(`${label}: cannot reach ${t.config.endpoint} — is the platform running?`))
  }
  let json = await res->responseJson
  switch json->field("errors") {
  | Some(errors) =>
    throw(
      Failed(`${label} failed\n  query: ${query}\n  response: ${JSON.stringify(errors)}`),
    )
  | None => json->field("data")->Option.getOr(JSON.Encode.null)
  }
}

// ── Commands ────────────────────────────────────────────────────────────────

let commandResultSelection = `__typename
  ... on CommandAccepted { eventCount }
  ... on CommandRejected { errorCode errorDetail }`

/**
 * Issues one command and insists it was accepted.
 *
 * `tolerate` names error codes that are an expected outcome of the domain
 * rather than a broken seed; a tolerated rejection is returned to the caller so
 * it can report on them instead of failing.
 */
let send = async (t: t, m: mutation, ~tolerate: array<string>=[]): option<string> => {
  let label = m->describe
  let query = `mutation { r: ${m.field}(${m.args->renderArgs}) { ${commandResultSelection} } }`
  let data = await gql(t, ~query, ~label)
  let result = data->field("r")->Option.getOr(JSON.Encode.null)
  switch result->nodeString("__typename") {
  | Some("CommandRejected") =>
    let code = result->nodeString("errorCode")->Option.getOr("unknown")
    let detail = result->nodeString("errorDetail")->Option.getOr("none")
    if tolerate->Array.includes(code) {
      Some(code)
    } else {
      throw(Failed(`${label} was rejected\n  errorCode: ${code}\n  errorDetail: ${detail}`))
    }
  | _ => None
  }
}

let sendAll = async (t: t, mutations: array<mutation>): unit =>
  for i in 0 to mutations->Array.length - 1 {
    switch mutations->Array.get(i) {
    | Some(m) => (await send(t, m))->ignore
    | None => ()
    }
  }

// ── Queries ─────────────────────────────────────────────────────────────────

/**
 * Walks a Relay-style connection to the end. Connections page at 50 by default,
 * so any count taken from a single request silently truncates.
 */
// `~args` is spliced into the connection's argument list — `"includeRetired: true"`
// is the case it exists for, and the only way to read rows the resolvers withhold
// by default. Literal GraphQL rather than a typed argument list because a seed
// writes the query it means; the alternative is a builder that has to grow a case
// per argument the platform adds.
let queryAllNodes = async (
  t: t,
  ~field as fieldName: string,
  ~selection: string,
  ~args: string="",
): array<JSON.t> => {
  let nodes = []
  let after = ref(None)
  let more = ref(true)
  let extra = args == "" ? "" : `, ${args}`
  while more.contents {
    let cursor = switch after.contents {
    | Some(c) => `, after: ${quote(c)}`
    | None => ""
    }
    let query = `{ ${fieldName}(first: 100${extra}${cursor}) { edges { node { ${selection} } } pageInfo { hasNextPage endCursor } } }`
    let data = await gql(t, ~query, ~label=fieldName)
    let connection = data->field(fieldName)->Option.getOr(JSON.Encode.null)
    switch connection->field("edges") {
    | Some(Array(edges)) =>
      edges->Array.forEach(edge =>
        switch edge->field("node") {
        | Some(node) => nodes->Array.push(node)
        | None => ()
        }
      )
    | _ => ()
    }
    let pageInfo = connection->field("pageInfo")->Option.getOr(JSON.Encode.null)
    let hasNext = switch pageInfo->field("hasNextPage") {
    | Some(Boolean(b)) => b
    | _ => false
    }
    let endCursor = pageInfo->nodeString("endCursor")
    switch (hasNext, endCursor) {
    | (true, Some(c)) => after := Some(c)
    | _ => more := false
    }
  }
  nodes
}

let countNodes = async (t: t, ~field: string): int =>
  (await queryAllNodes(t, ~field, ~selection="id"))->Array.length

/**
 * Polls a connection field until the collected nodes satisfy `satisfied`, or the
 * timeout elapses. Read models are eventually consistent: a view queried the
 * instant after the writes that feed it can still read empty or partial (a
 * DynamoDB connection scan is eventually consistent by default, and the write and
 * read-back can land on different replicas), so a cross-check that asserts on a
 * single immediate read races the projection. Same rationale as `waitForIds`,
 * for the "observe the whole connection" case rather than a fixed id set.
 *
 * On timeout, throws `Failed(onTimeout(finalNodes))` so the caller can report
 * what the view actually settled on — distinguishing a still-empty view from a
 * genuine count mismatch — instead of a bare assertion.
 */
let queryAllNodesUntil = async (
  t: t,
  ~field: string,
  ~selection: string,
  ~args: string="",
  ~satisfied: array<JSON.t> => bool,
  ~onTimeout: array<JSON.t> => string,
  ~timeoutMs: int=60000,
): array<JSON.t> => {
  let deadline = nowMs() +. Int.toFloat(timeoutMs)
  let result = ref(None)
  while result.contents == None {
    let nodes = await queryAllNodes(t, ~field, ~selection, ~args)
    if satisfied(nodes) {
      result := Some(nodes)
    } else if nowMs() > deadline {
      throw(Failed(onTimeout(nodes)))
    } else {
      await sleep(500)
    }
  }
  result.contents->Option.getOr([])
}

/**
 * Polls a `<View>ByIds` field until every id is present.
 *
 * Cross-plugin propagation (extension point → extension → command) is
 * asynchronous, so a seed that places orders immediately after creating
 * products would race the shadow copy. Waiting on the observable result beats
 * sleeping and hoping.
 */
let waitForIds = async (
  t: t,
  ~field as fieldName: string,
  ~ids: array<string>,
  ~timeoutMs: int=60000,
): int => {
  let deadline = nowMs() +. Int.toFloat(timeoutMs)
  let idList = ids->Array.map(id => quote(id))->Array.join(", ")
  let result = ref(None)
  while result.contents == None {
    let query = `{ ${fieldName}(ids: [${idList}]) { id } }`
    let data = await gql(t, ~query, ~label=fieldName)
    let found = switch data->field(fieldName) {
    | Some(Array(rows)) => rows
    | _ => []
    }
    if found->Array.length >= ids->Array.length {
      result := Some(found->Array.length)
    } else if nowMs() > deadline {
      let present = found->Array.filterMap(row => row->nodeString("id"))
      let missing = ids->Array.filter(id => !(present->Array.includes(id)))
      let shown = missing->Array.slice(~start=0, ~end=10)->Array.join(", ")
      let extra =
        missing->Array.length > 10 ? ` (+${(missing->Array.length - 10)->Int.toString} more)` : ""
      throw(
        Failed(
          `only ${(found->Array.length)->Int.toString}/${(ids->Array.length)
              ->Int.toString} ids reached ${fieldName} within ${timeoutMs->Int.toString}ms.\n  missing: ${shown}${extra}`,
        ),
      )
    } else {
      await sleep(250)
    }
  }
  result.contents->Option.getOr(0)
}
