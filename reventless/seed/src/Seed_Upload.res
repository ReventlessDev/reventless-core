// Seed-time asset upload against the framework's presign-shaped upload contract.
//
// One code path for both providers: the AWS `Upload_Presign_S3` Function URL and
// the local dev upload route expose the SAME shape — POST `{fileName,contentType}`
// → `{uploadUrl, storageRef}`, then PUT the bytes to `uploadUrl`. `uploadAsset`
// resolves `Ok(storageRef)` — the same same-origin `/{prefix}/{key}` ref a command
// stores and the UI renders.
//
// The seed runs under Node, so the returned `uploadUrl` is resolved to an
// absolute URL against the endpoint's origin: AWS returns an absolute presigned
// S3 URL (unchanged), while the local route returns a same-origin relative
// `/{prefix}/{key}` that Node's `fetch` cannot PUT to until it is made absolute.

type fetchInit = {method: string, headers: dict<string>, body: string}
type response

@val external fetch: (string, fetchInit) => promise<response> = "fetch"
@send external responseJson: response => promise<JSON.t> = "json"
@send external responseText: response => promise<string> = "text"
@get external responseOk: response => bool = "ok"
@get external responseStatus: response => int = "status"

// Resolve a possibly-relative URL against a base (WHATWG URL semantics: an
// absolute `input` ignores `base`, a relative one is resolved against it).
type url
@new external makeUrl: (string, string) => url = "URL"
@get external urlHref: url => string = "href"

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

// A `fetch` that reports an unreachable endpoint as `Error` instead of throwing,
// so the two-step upload can thread failures without exceptions.
let tryFetch = async (url: string, init: fetchInit): result<response, string> =>
  try Ok(await fetch(url, init)) catch {
  | _ => Error(`cannot reach ${url}`)
  }

/**
 * Uploads `bytes` under `fileName`/`contentType` through `uploadEndpoint` and
 * resolves `Ok(storageRef)` (the stored `/{prefix}/{key}` ref), or `Error(msg)`
 * describing the step that failed. `authToken`, when supplied, is sent as a
 * Bearer on the presign request (the endpoint decides whether it is required;
 * the PUT itself is unauthenticated — presigned on AWS, open locally).
 */
let uploadAsset = async (
  ~uploadEndpoint: string,
  ~bytes: string,
  ~fileName: string,
  ~contentType: string,
  ~authToken: option<string>=?,
): result<string, string> => {
  let presignHeaders = Dict.fromArray([("content-type", "application/json")])
  authToken->Option.forEach(t => presignHeaders->Dict.set("authorization", `Bearer ${t}`))
  let presignBody = JSON.stringify(
    JSON.Encode.object(
      Dict.fromArray([
        ("fileName", JSON.Encode.string(fileName)),
        ("contentType", JSON.Encode.string(contentType)),
      ]),
    ),
  )

  switch await tryFetch(uploadEndpoint, {method: "POST", headers: presignHeaders, body: presignBody}) {
  | Error(m) => Error(`presign: ${m} — is the platform running?`)
  | Ok(presignRes) if !(presignRes->responseOk) =>
    let detail = await presignRes->responseText
    Error(`presign failed with HTTP ${(presignRes->responseStatus)->Int.toString}: ${detail}`)
  | Ok(presignRes) =>
    let json = await presignRes->responseJson
    switch (
      json->field("uploadUrl")->Option.flatMap(asString),
      json->field("storageRef")->Option.flatMap(asString),
    ) {
    | (Some(uploadUrl), Some(storageRef)) =>
      let putUrl = urlHref(makeUrl(uploadUrl, uploadEndpoint))
      switch await tryFetch(
        putUrl,
        {method: "PUT", headers: Dict.fromArray([("content-type", contentType)]), body: bytes},
      ) {
      | Error(m) => Error(`upload PUT: ${m}`)
      | Ok(putRes) if putRes->responseOk => Ok(storageRef)
      | Ok(putRes) =>
        let detail = await putRes->responseText
        Error(`upload PUT failed with HTTP ${(putRes->responseStatus)->Int.toString}: ${detail}`)
      }
    | _ => Error("presign response missing uploadUrl/storageRef")
    }
  }
}
