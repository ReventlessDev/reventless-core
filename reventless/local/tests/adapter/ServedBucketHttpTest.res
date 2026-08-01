// End-to-end test for the local upload contract on DomainGraphQL_Server (route B, the
// dev analogue of the AWS presign + serve + release loop). Boots a real server on a
// private port with the Upload resolvers registered (as `makePlatform` does), then
// exercises the full loop:
//   mutation Upload_Presign  → {uploadUrl, storageRef}
//   PUT  /{prefix}/{key}     → 200 (store)
//   GET  /{prefix}/{key}     → the stored bytes + content-type
//   mutation Upload_Release  → {released: true}
//   GET  /{prefix}/{key}     → 404 (gone)
// Talks to the server over node:http (Jest 27's VM strips global fetch), same as
// LocalAuthHttpTest. Mint and release are GraphQL mutations under route B; the byte
// PUT/GET stay HTTP data-plane routes.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()

// High ephemeral port, clear of dev-server defaults and the auth HTTP test.
let port = 49322

// ── Minimal node:http helpers ───────────────────────────────────────────────

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
@get external _resHeaders: httpRes => dict<string> = "headers"

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
            let parsed = try buf.contents->JSON.parseOrThrow catch {
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

// PUT a raw (ASCII) body to a served-object path. Content-length is byte-safe
// only for ASCII payloads, which the SVG fixture below is.
let putRaw = (path: string, body: string, ~contentType: string): promise<int> =>
  Promise.make((resolve, reject) => {
    let req =
      _request(
        {
          hostname: "localhost",
          port,
          path,
          method: "PUT",
          headers: Dict.fromArray([
            ("content-type", contentType),
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

let getRaw = (path: string): promise<(int, string, string)> =>
  Promise.make((resolve, reject) => {
    let req =
      _request(
        {hostname: "localhost", port, path, method: "GET", headers: Dict.make()},
        res => {
          let status = _resStatusCode(res)
          let contentType = _resHeaders(res)->Dict.get("content-type")->Option.getOr("")
          let buf = ref("")
          res->_resSetEncoding("utf8")
          res->_resOnData(chunk => buf := buf.contents ++ Obj.magic(chunk))
          res->_resOnEnd(() => resolve((status, buf.contents, contentType)))
        },
      )
    req->_reqOnError(err => reject(Obj.magic(err)))
    req->_reqEnd
  })

let getString = (j: JSON.t, k: string): string =>
  j->JSON.Decode.object->Option.flatMap(d => d->Dict.get(k))->Option.flatMap(JSON.Decode.string)->Option.getOr("")

// ── Lifecycle ────────────────────────────────────────────────────────────────

// Extract `data.r` from a GraphQL response body.
let mutationResult = (body: JSON.t): JSON.t =>
  body
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("data"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("r"))
  ->Option.getOr(JSON.Encode.null)

let presign = async (~fileName: string): JSON.t => {
  let q = `mutation { r: Upload_Presign(store: "x.y", fileName: "${fileName}", contentType: "image/svg+xml") { uploadUrl storageRef } }`
  let (_, body) = await postJson("/graphql", Dict.fromArray([("query", JSON.Encode.string(q))]))
  mutationResult(body)
}

let releaseRef = async (~storageRef: string): JSON.t => {
  let q = `mutation { r: Upload_Release(store: "x.y", storageRef: "${storageRef}") { released reason } }`
  let (_, body) = await postJson("/graphql", Dict.fromArray([("query", JSON.Encode.string(q))]))
  mutationResult(body)
}

beforeAllAsync(async () => {
  DomainGraphQL_Server.reset()
  // Minimal valid schema: relay base (a Query type must exist) plus the Upload
  // mutations, registered exactly as makePlatform does via LocalUploadResolvers.
  DomainGraphQL_Server.registerTypes(~sdlTypes=ReventlessCore.GraphQL_Stitcher.relayBaseTypes)
  DomainGraphQL_Server.registerQueries(
    ~sdlFields=ReventlessCore.GraphQL_Stitcher.relayBaseQueries,
    ~resolvers=Dict.make(),
  )
  LocalUploadResolvers.register(DomainGraphQL_Server.asInterface)
  DomainGraphQL_Server.start(~port, ())
  await Promise.make((resolve, _) => setTimeout(() => resolve(), 50)->ignore)
})

afterAll(() => {
  DomainGraphQL_Server.stop()
})

// ── Tests ──────────────────────────────────────────────────────────────────

testPromise("Upload_Presign returns matching uploadUrl + storageRef under the prefix", async () => {
  let r = await presign(~fileName="logo.svg")
  let uploadUrl = getString(r, "uploadUrl")
  let storageRef = getString(r, "storageRef")
  // Same same-origin ref serves as both the PUT target and the stored value.
  expect(uploadUrl)->toEqual(storageRef)
  expect(storageRef->String.startsWith("/uploads/"))->toEqual(true)
  expect(storageRef->String.endsWith("/logo.svg"))->toEqual(true)
})

testPromise("presign → PUT → GET → release → GET(404) is the full loop", async () => {
  let r = await presign(~fileName="pixel.svg")
  let ref = getString(r, "storageRef")
  let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>"

  let putStatus = await putRaw(ref, svg, ~contentType="image/svg+xml")
  expect(putStatus)->toEqual(200)

  let (getStatus, gotBody, gotContentType) = await getRaw(ref)
  expect(getStatus)->toEqual(200)
  expect(gotBody)->toEqual(svg)
  expect(gotContentType)->toEqual("image/svg+xml")

  let released = await releaseRef(~storageRef=ref)
  expect(released->JSON.Decode.object->Option.flatMap(d => d->Dict.get("released")))->toEqual(
    Some(JSON.Encode.bool(true)),
  )

  // After release the object is gone.
  let (goneStatus, _, _) = await getRaw(ref)
  expect(goneStatus)->toEqual(404)
})

testPromise("Upload_Release of a ref outside a served prefix is refused with a reason", async () => {
  let r = await releaseRef(~storageRef="/not-a-store/x/y.svg")
  expect(r->JSON.Decode.object->Option.flatMap(d => d->Dict.get("released")))->toEqual(
    Some(JSON.Encode.bool(false)),
  )
  expect(getString(r, "reason"))->toEqual("not_in_store")
})

testPromise("GET a missing served object returns 404", async () => {
  let (status, _, _) = await getRaw("/uploads/missing/none.svg")
  expect(status)->toEqual(404)
})
