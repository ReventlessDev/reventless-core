// Runtime handler for the AWS Location geocoder — compiled, type-checked, and
// Pulumi-free so it can be shipped as an EntryPoint module (`Geocoder_AwsLocation`
// bundles it and re-exports `handler` from the code archive). Keeping it out of
// the deploy-time module avoids both the serialized-closure SDK skew and a
// deploy-time Pulumi import leaking into the Lambda's cold-start graph.
//
// Reads a `q` query-string param from the Function URL event, calls
// SearchPlaceIndexForText against `PLACE_INDEX_NAME`, and returns
// `[{label, lat, lng}]` as JSON. Any failure degrades to an empty array so the
// caller never sees a hard error.

// AWS Location lives in the bindings package, shared with the backend geocoder
// adapter — one place owns the `[lng, lat]` order and the optional `Relevance`.
module Search = AwsSdk.Location.SearchPlaceIndexForTextCommand

@val external decodeURIComponent: string => string = "decodeURIComponent"

// ── Node bindings (replacing the former `%raw` env helper with a typed one) ──


// Read an env var, mapping "" / unset to None.
let getEnv = (k: string): option<string> =>
  switch NodeProcess.env->Dict.get(k) {
  | Some("") | None => None
  | Some(v) => Some(v)
  }

// ── Function URL event / response shapes (payload format 2.0) ────────────────

type functionUrlEvent = {
  rawQueryString?: string,
  queryStringParameters?: dict<string>,
}

type response = {
  statusCode: int,
  headers?: dict<string>,
  body: string,
}

// CORS belongs to the Function URL's own `cors` configuration and to nothing
// else. AWS injects the allow-origin header itself whenever the request carries
// an `Origin`, so a handler that also sets one sends the header *twice* — and a
// browser rejects `Access-Control-Allow-Origin: *, *` outright, failing every
// cross-origin call while leaving `curl` (which sends no `Origin`, so AWS adds
// nothing) working perfectly.
//
// It is also the only way `~corsOrigins` can mean anything: a hardcoded `*`
// here would keep answering `*` for a deployment that narrowed the allow-list.
let jsonHeaders = () => Dict.fromArray([("content-type", "application/json")])

// Pull `q` from the parsed query-string params, falling back to the raw string.
let readQueryParam = (event: functionUrlEvent): option<string> =>
  switch event.queryStringParameters->Option.flatMap(p => p->Dict.get("q")) {
  | Some(q) => Some(q)
  | None =>
    event.rawQueryString->Option.flatMap(raw =>
      raw
      ->String.split("&")
      ->Array.findMap(pair =>
        switch pair->String.split("=") {
        | [k, v] if k == "q" => Some(v->decodeURIComponent)
        | _ => None
        }
      )
    )
  }

// ── Runtime handler ─────────────────────────────────────────────────────────

let handler = async (event: functionUrlEvent): response => {
  try {
    let indexName = getEnv("PLACE_INDEX_NAME")->Option.getOr("")
    let q = readQueryParam(event)->Option.getOr("")
    if indexName == "" {
      // A handler with no place index cannot answer anything, so this is the
      // service being misconfigured — not a verdict on the address. It has to
      // read as `502` for the same reason the catch below does: a `200 []` here
      // tells an unattended caller "no such address", and it would then write
      // that verdict, unretried, for every address it is handed while the
      // deployment is broken. The browser is unaffected — it reads the body.
      Console.error("Geocoder: PLACE_INDEX_NAME is unset")
      {statusCode: 502, headers: jsonHeaders(), body: "[]"}
    } else if q == "" {
      // `200`, unlike the arm above: nothing was asked, so "no results" is a
      // true and final answer rather than a failure to produce one. A search box
      // sends this on every cleared input.
      {statusCode: 200, headers: jsonHeaders(), body: "[]"}
    } else {
      let resp = await Search.send(Search.make({indexName, text: q, maxResults: 5}))
      let results =
        resp.results
        ->Option.getOr([])
        ->Array.filterMap(r =>
          switch r.place {
          | Some(place) =>
            let label = place.label->Option.getOr("")
            switch place.geometry->Option.flatMap(g => g.point) {
            | Some(pt) if pt->Array.length >= 2 =>
              let lng = pt->Array.getUnsafe(0)
              let lat = pt->Array.getUnsafe(1)
              Some(
                Dict.fromArray(
                  Array.concat(
                    [
                      ("label", JSON.Encode.string(label)),
                      ("lat", JSON.Encode.float(lat)),
                      ("lng", JSON.Encode.float(lng)),
                    ],
                    // Additive: the browser client reads the three fields above
                    // and ignores this one. An unattended caller needs it to
                    // apply `Geocoding.confidentMatch`, which is what keeps a
                    // vague match from becoming a confident pin.
                    switch r.relevance {
                    | Some(rel) => [("relevance", JSON.Encode.float(rel))]
                    | None => []
                    },
                  ),
                )->JSON.Encode.object,
              )
            | _ => None
            }
          | None => None
          }
        )
      {
        statusCode: 200,
        headers: jsonHeaders(),
        body: results->JSON.Encode.array->JSON.stringify,
      }
    }
  } catch {
  | exn =>
    Console.error2("Geocoder: search failed", exn)
    // 502, not 200 — and still `[]`, which is the point. A browser search box
    // reads the body and degrades to "no results" whether or not it checks the
    // status, so nothing on that side changes. An unattended caller reads the
    // status and can tell "the service is down" from "there is no such address",
    // which is the difference between retrying and writing a verdict into an
    // event log. One contract serves both because they disagree only about which
    // half of the response they read.
    {statusCode: 502, headers: jsonHeaders(), body: "[]"}
  }
}
