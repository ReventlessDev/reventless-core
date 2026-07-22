// Stage A4 — end-to-end test for the POST /__inmemory/login + /logout HTTP
// endpoints. Boots a real DomainGraphQL_Server on a private port, posts
// credentials with the global `fetch` (Node 22+), then stops the server.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()

// High port in the dynamic/ephemeral range — deliberately clear of well-known
// dev-server defaults (Astro 4321, Vite 5173, 3000/4000/8080) so a running dev
// server doesn't shadow this test's server via EADDRINUSE (the listen success
// callback never fires on collision, and requests silently hit the other server).
let port = 49321

// ── Minimal node:http POST helper ──────────────────────────────────────────
// Jest 27's VM context strips Node's global `fetch` (and undici needs more
// polyfills than we want to maintain), so the test talks to the server via
// `node:http` directly. Same wire format — the SPA still uses fetch.

type httpRequestOptions = {
  hostname: string,
  port: int,
  path: string,
  method: string,
  headers: dict<string>,
}
type httpReq
type httpRes
@module("node:http") external _request: (httpRequestOptions, httpRes => unit) => httpReq = "request"
@send external _reqWrite: (httpReq, string) => unit = "write"
@send external _reqEnd: (httpReq, @as(json`null`) _) => unit = "end"
@send external _reqOnError: (httpReq, @as("error") _, 'err => unit) => unit = "on"
@send external _resOnData: (httpRes, @as("data") _, 'chunk => unit) => unit = "on"
@send external _resOnEnd: (httpRes, @as("end") _, unit => unit) => unit = "on"
@send external _resSetEncoding: (httpRes, string) => unit = "setEncoding"
@get external _resStatusCode: httpRes => int = "statusCode"

let postJson = (path: string, body: dict<JSON.t>): promise<(int, JSON.t)> =>
  Promise.make((resolve, reject) => {
    let bodyStr = body->JSON.Encode.object->JSON.stringify
    let req =
      _request(
        {
          hostname: "localhost",
          port,
          path,
          method: "POST",
          headers: Dict.fromArray([
            ("content-type", "application/json"),
            ("content-length", bodyStr->String.length->Int.toString),
          ]),
        },
        res => {
          let status = _resStatusCode(res)
          let buf = ref("")
          res->_resSetEncoding("utf8")
          res->_resOnData(chunk => buf := buf.contents ++ Obj.magic(chunk))
          res->_resOnEnd(() => {
            let parsed = try {
              buf.contents->JSON.parseOrThrow
            } catch {
            | _ => JSON.Encode.null
            }
            resolve((status, parsed))
          })
        },
      )
    req->_reqOnError(err => reject(Obj.magic(err)))
    req->_reqWrite(bodyStr)
    req->_reqEnd
  })

let postEmpty = (path: string): promise<int> =>
  Promise.make((resolve, reject) => {
    let req =
      _request(
        {hostname: "localhost", port, path, method: "POST", headers: Dict.make()},
        res => {
          let status = _resStatusCode(res)
          // Drain (otherwise the socket may stay open under HTTP keep-alive).
          res->_resOnData(_ => ())
          res->_resOnEnd(() => resolve(status))
        },
      )
    req->_reqOnError(err => reject(Obj.magic(err)))
    req->_reqEnd
  })

let postRaw = (path: string, body: string): promise<int> =>
  Promise.make((resolve, reject) => {
    let req =
      _request(
        {
          hostname: "localhost",
          port,
          path,
          method: "POST",
          headers: Dict.fromArray([
            ("content-type", "application/json"),
            ("content-length", body->String.length->Int.toString),
          ]),
        },
        res => {
          let status = _resStatusCode(res)
          res->_resOnData(_ => ())
          res->_resOnEnd(() => resolve(status))
        },
      )
    req->_reqOnError(err => reject(Obj.magic(err)))
    req->_reqWrite(body)
    req->_reqEnd
  })

let getJsonField = (j: JSON.t, k: string): option<JSON.t> =>
  j->JSON.Decode.object->Option.flatMap(d => d->Dict.get(k))

let getString = (j: JSON.t, k: string): string =>
  getJsonField(j, k)->Option.flatMap(JSON.Decode.string)->Option.getOr("")

// ── Lifecycle ──────────────────────────────────────────────────────────────

beforeAllAsync(async () => {
  LocalAuth.resetUsers()
  LocalAuth.Login.resetStore()
  LocalAuth.Login.setTokenSecret("http-test-secret")
  LocalAuth.Login.setCredentials(
    ~username="alice",
    ~password="alice-pw",
    ~identity={
      userId: "u-alice",
      username: "alice",
      groups: ["Editor"],
      provider: InMemory,
    },
  )
  DomainGraphQL_Server.reset()
  DomainGraphQL_Server.start(~port, ())
  // Give the listener a tick to bind.
  await Promise.make((resolve, _) => setTimeout(() => resolve(), 50)->ignore)
})

afterAll(() => {
  DomainGraphQL_Server.stop()
})

// ── Tests ──────────────────────────────────────────────────────────────────

testPromise("POST /__inmemory/login returns {token, identity} for valid credentials", async () => {
  let (status, body) =
    await postJson(
      "/__inmemory/login",
      Dict.fromArray([
        ("username", JSON.Encode.string("alice")),
        ("password", JSON.Encode.string("alice-pw")),
      ]),
    )
  expect(status)->toEqual(200)
  let token = getString(body, "token")
  expect(token->String.length > 0)->toEqual(true)
  expect(token->String.includes("."))->toEqual(true)
  // The echoed identity matches what LocalAuth.lookupUser returns.
  switch getJsonField(body, "identity") {
  | Some(idJson) =>
    let id = idJson->S.parseJsonOrThrow(Reventless.Identity.schema)
    expect(id.username)->toEqual("alice")
    expect(id.groups)->toEqual(["Editor"])
  | None => JsError.throwWithMessage("response missing identity field")
  }
})

testPromise("POST /__inmemory/login returns 401 for wrong password", async () => {
  let (status, body) =
    await postJson(
      "/__inmemory/login",
      Dict.fromArray([
        ("username", JSON.Encode.string("alice")),
        ("password", JSON.Encode.string("WRONG")),
      ]),
    )
  expect(status)->toEqual(401)
  expect(getString(body, "error")->String.length > 0)->toEqual(true)
})

testPromise("POST /__inmemory/login returns 401 for missing user", async () => {
  let (status, _) =
    await postJson(
      "/__inmemory/login",
      Dict.fromArray([
        ("username", JSON.Encode.string("ghost")),
        ("password", JSON.Encode.string("x")),
      ]),
    )
  expect(status)->toEqual(401)
})

testPromise("POST /__inmemory/login returns 401 for malformed JSON body", async () => {
  let status = await postRaw("/__inmemory/login", "not-json")
  expect(status)->toEqual(401)
})

testPromise("POST /__inmemory/logout always returns 204", async () => {
  let status = await postEmpty("/__inmemory/logout")
  expect(status)->toEqual(204)
})

testPromise("Bearer token issued via HTTP round-trips through authenticate", async () => {
  let (_, body) =
    await postJson(
      "/__inmemory/login",
      Dict.fromArray([
        ("username", JSON.Encode.string("alice")),
        ("password", JSON.Encode.string("alice-pw")),
      ]),
    )
  let token = getString(body, "token")
  let result =
    await LocalAuth.authenticate({
      headers: Dict.fromArray([("authorization", "Bearer " ++ token)]),
    })
  switch result {
  | Authenticated(identity) =>
    expect(identity.username)->toEqual("alice")
    expect(identity.groups)->toEqual(["Editor"])
  | _ => JsError.throwWithMessage("expected Authenticated(alice) from issued token")
  }
})
