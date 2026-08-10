// Retry wrapper for npmjs registry reads.
//
// npmjs serves freshly-published packages through a Cloudflare CDN that has
// read-after-write propagation lag: a packument or tarball can 404 for a short
// window after `lerna publish` returns. This layer build is dispatched by
// release.yml immediately after publishing, so it routinely races that window
// (observed: aws@N extracted fine while core@M's packument 404'd ~3.5 min after
// both were published). npm-registry-fetch treats E404 as terminal — it only
// retries network errors, 5xx and 429 — so the build dies on a pure transient.
// Retry the registry reads here with exponential backoff; repeated requests hit
// different CDN edges and converge once the package has propagated.

@get external errorCode: JsExn.t => option<string> = "code"
@get external errorStatusCode: JsExn.t => option<int> = "statusCode"

let transientCodes = [
  "E404",
  "ETARGET",
  "ETIMEDOUT",
  "ECONNRESET",
  "ECONNREFUSED",
  "EAI_AGAIN",
  "ENOTFOUND",
]

let isTransient = exn =>
  switch exn->JsExn.fromException {
  | Some(e) =>
    let code = e->errorCode->Option.getOr("")
    let status = e->errorStatusCode->Option.getOr(0)
    transientCodes->Array.includes(code) || status === 404 || status === 429 || status >= 500
  | None => false
  }

let sleep = async ms =>
  await Promise.make((resolve, _reject) => {
    let _ = setTimeout(() => resolve(), ms)
  })

// Exponential backoff, capped at 60s — ~5 min of headroom across 10 attempts.
// The window covers packument skew as well as tarball lag: a multi-package
// upstream release (e.g. the @aws-sdk/* fan-out, where lib-dynamodb pins a peer
// on the same-version client-dynamodb) can leave one package resolvable and its
// sibling missing for minutes, surfacing as ETARGET.
let backoffMs = [2000, 4000, 8000, 16000, 30000, 60000]

let withRetry = async (~label, ~maxAttempts=10, fn) => {
  let rec go = async attempt =>
    try {
      await fn()
    } catch {
    | exn =>
      if isTransient(exn) && attempt < maxAttempts {
        let idx = attempt - 1
        let delayMs =
          backoffMs->Array.get(idx)->Option.getOr(backoffMs->Array.getUnsafe(backoffMs->Array.length - 1))
        Console.warn(
          "[registry-retry] " ++
          label ++
          ": transient failure on attempt " ++
          attempt->Int.toString ++
          "/" ++
          maxAttempts->Int.toString ++
          ", retrying in " ++
          (delayMs / 1000)->Int.toString ++ "s",
        )
        await sleep(delayMs)
        await go(attempt + 1)
      } else {
        throw(exn)
      }
    }
  await go(1)
}
