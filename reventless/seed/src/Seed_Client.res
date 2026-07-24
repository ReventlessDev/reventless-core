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
  loginEndpoint: string,
  username: string,
  password: string,
}

type t = {config: config, mutable token: option<string>}

let make = (~config: config): t => {config, token: None}

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
  let body = JSON.stringify(
    JSON.Encode.object(
      Dict.fromArray([
        ("username", JSON.Encode.string(t.config.username)),
        ("password", JSON.Encode.string(t.config.password)),
      ]),
    ),
  )
  let res = try await fetch(
    t.config.loginEndpoint,
    {method: "POST", headers: Dict.fromArray([("content-type", "application/json")]), body},
  ) catch {
  | _ =>
    throw(
      Failed(`login: cannot reach ${t.config.loginEndpoint} — is the platform running?`),
    )
  }
  if !(res->responseOk) {
    let detail = await res->responseText
    throw(
      Failed(
        `login as "${t.config.username}" failed with HTTP ${(res->responseStatus)
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

/**
 * InboundTranslationSlice mutations are declared as returning `CommandResult!`
 * but their resolver returns the translated target-id array, so the GraphQL
 * runtime cannot resolve the union and every call comes back as an error even
 * when the import succeeded. Tolerate exactly that shape and verify the outcome
 * through the slice's audit view instead. Delete this once the resolver is
 * fixed — a real failure would otherwise hide behind it.
 */
let sendInboundTranslation = async (t: t, m: mutation): unit => {
  let label = m->describe
  let query = `mutation { r: ${m.field}(${m.args->renderArgs}) { __typename } }`
  try (await gql(t, ~query, ~label))->ignore catch {
  | Failed(message)
    if message->String.includes("must resolve to an Object type") &&
      message->String.includes("CommandResult") => ()
  }
}

// ── Queries ─────────────────────────────────────────────────────────────────

/**
 * Walks a Relay-style connection to the end. Connections page at 50 by default,
 * so any count taken from a single request silently truncates.
 */
let queryAllNodes = async (t: t, ~field as fieldName: string, ~selection: string): array<
  JSON.t,
> => {
  let nodes = []
  let after = ref(None)
  let more = ref(true)
  while more.contents {
    let cursor = switch after.contents {
    | Some(c) => `, after: ${quote(c)}`
    | None => ""
    }
    let query = `{ ${fieldName}(first: 100${cursor}) { edges { node { ${selection} } } pageInfo { hasNextPage endCursor } } }`
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
