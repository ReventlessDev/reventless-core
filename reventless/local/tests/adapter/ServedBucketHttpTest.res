// End-to-end test for the local served-bucket HTTP routes on DomainGraphQL_Server
// (the dev analogue of the AWS CloudFront read path). Boots a real server on a
// private port, then exercises the full upload → store → serve loop:
//   POST /__inmemory/upload → {uploadUrl, storageRef}
//   PUT  /{prefix}/{key}    → 200 (store)
//   GET  /{prefix}/{key}    → the stored bytes + content-type
// Talks to the server over node:http (Jest 27's VM strips global fetch), same
// as LocalAuthHttpTest.

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

beforeAllAsync(async () => {
  DomainGraphQL_Server.reset()
  DomainGraphQL_Server.start(~port, ())
  await Promise.make((resolve, _) => setTimeout(() => resolve(), 50)->ignore)
})

afterAll(() => {
  DomainGraphQL_Server.stop()
})

// ── Tests ──────────────────────────────────────────────────────────────────

testPromise("POST /__inmemory/upload returns matching uploadUrl + storageRef under the prefix", async () => {
  let (status, body) =
    await postJson(
      "/__inmemory/upload",
      Dict.fromArray([
        ("fileName", JSON.Encode.string("logo.svg")),
        ("contentType", JSON.Encode.string("image/svg+xml")),
      ]),
    )
  expect(status)->toEqual(200)
  let uploadUrl = getString(body, "uploadUrl")
  let storageRef = getString(body, "storageRef")
  // Same same-origin ref serves as both the PUT target and the stored value.
  expect(uploadUrl)->toEqual(storageRef)
  expect(storageRef->String.startsWith("/uploads/"))->toEqual(true)
  expect(storageRef->String.endsWith("/logo.svg"))->toEqual(true)
})

testPromise("PUT then GET round-trips the bytes and content-type", async () => {
  let (_, body) =
    await postJson(
      "/__inmemory/upload",
      Dict.fromArray([("fileName", JSON.Encode.string("pixel.svg"))]),
    )
  let ref = getString(body, "storageRef")
  let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>"

  let putStatus = await putRaw(ref, svg, ~contentType="image/svg+xml")
  expect(putStatus)->toEqual(200)

  let (getStatus, gotBody, gotContentType) = await getRaw(ref)
  expect(getStatus)->toEqual(200)
  expect(gotBody)->toEqual(svg)
  expect(gotContentType)->toEqual("image/svg+xml")
})

testPromise("GET a missing served object returns 404", async () => {
  let (status, _, _) = await getRaw("/uploads/missing/none.svg")
  expect(status)->toEqual(404)
})
