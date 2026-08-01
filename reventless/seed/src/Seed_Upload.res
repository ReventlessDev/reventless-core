// Seed-time asset upload against the framework's upload contract (route B).
//
// Minting is a GraphQL mutation on the domain API — `Upload_Presign(store, fileName,
// contentType)` — authenticated by the same bearer the seed already uses for commands
// (no separate endpoint, no anonymous surface). `uploadAsset` issues it through the
// shared `Seed_Client`, then PUTs the bytes to the returned `uploadUrl` and resolves
// `Ok(storageRef)` — the same `/{prefix}/{key}` ref a command stores and the UI renders.
//
// The seed runs under Node, so a relative `uploadUrl` (the local dev server returns a
// same-origin `/{prefix}/{key}`) is resolved to an absolute URL against the client's
// endpoint origin before the PUT; AWS returns an absolute presigned S3 URL (used as-is).
// The PUT itself is unauthenticated — presigned on AWS, open on the local route.

type fetchInit = {method: string, headers: dict<string>, body: string}
type response

@val external fetch: (string, fetchInit) => promise<response> = "fetch"
@send external responseText: response => promise<string> = "text"
@get external responseOk: response => bool = "ok"
@get external responseStatus: response => int = "status"

// Resolve a possibly-relative URL against a base (WHATWG URL semantics: an absolute
// `input` ignores `base`, a relative one is resolved against it).
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

// Whether this run should skip uploads entirely. `SEED_SKIP_UPLOADS` seeds domain data
// fast, or skips a broken/absent upload path without editing the data set.
let uploadsSkipped = (): bool => Seed_Prompt.envValue("SEED_SKIP_UPLOADS")->Option.isSome

// A `fetch` that reports an unreachable endpoint as `Error` instead of throwing.
let tryFetch = async (url: string, init: fetchInit): result<response, string> =>
  try Ok(await fetch(url, init)) catch {
  | _ => Error(`cannot reach ${url}`)
  }

/**
 * Uploads `bytes` under `fileName`/`contentType` into `store` (the qualified
 * `{plugin}.{store}` the asset's field declares, e.g. `"Catalog.productImages"`) and
 * resolves `Ok(storageRef)` (the stored `/{prefix}/{key}` ref), or `Error(msg)`
 * describing the step that failed. Mints through the domain API's `Upload_Presign`
 * mutation on `client`, then PUTs the bytes to the returned `uploadUrl`.
 */
let uploadAsset = async (
  ~client: Seed_Client.t,
  ~store: string,
  ~bytes: string,
  ~fileName: string,
  ~contentType: string,
): result<string, string> => {
  // GraphQL string literals: JSON-quote the argument values (JSON string escaping is a
  // superset-safe subset of GraphQL's for these ASCII-ish inputs).
  let q = s => JSON.stringify(JSON.Encode.string(s))
  let query = `mutation { r: Upload_Presign(store: ${q(store)}, fileName: ${q(fileName)}, contentType: ${q(contentType)}) { uploadUrl storageRef } }`

  let presign = try Ok(await Seed_Client.gql(client, ~query, ~label="Upload_Presign")) catch {
  | Seed_Types.Failed(m) => Error(m)
  | _ => Error("Upload_Presign: unexpected error")
  }

  switch presign {
  | Error(m) => Error(`presign: ${m}`)
  | Ok(data) =>
    let r = data->field("r")->Option.getOr(JSON.Encode.null)
    switch (
      r->field("uploadUrl")->Option.flatMap(asString),
      r->field("storageRef")->Option.flatMap(asString),
    ) {
    | (Some(uploadUrl), Some(storageRef)) =>
      let putUrl = urlHref(makeUrl(uploadUrl, Seed_Client.endpoint(client)))
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
    | _ => Error("Upload_Presign response missing uploadUrl/storageRef")
    }
  }
}
