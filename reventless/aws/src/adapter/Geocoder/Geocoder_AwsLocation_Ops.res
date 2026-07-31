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

// ── AWS Location SDK bindings (AWS SDK v3, client.send(new Command(...))) ────

type locationClient

type searchPlaceIndexForTextInput = {
  @as("IndexName") indexName: string,
  @as("Text") text: string,
  @as("MaxResults") maxResults?: int,
}
// GeoJSON order: [lng, lat].
type point = array<float>
type geometry = {@as("Point") point?: point}
type place = {@as("Label") label?: string, @as("Geometry") geometry?: geometry}
type searchResult = {@as("Place") place?: place}
type searchResponse = {@as("Results") results?: array<searchResult>}
type searchCommand

@module("@aws-sdk/client-location") @new
external makeLocationClient: unit => locationClient = "LocationClient"

@module("@aws-sdk/client-location") @new
external makeSearchPlaceIndexForTextCommand: searchPlaceIndexForTextInput => searchCommand =
  "SearchPlaceIndexForTextCommand"

@send external send: (locationClient, searchCommand) => promise<searchResponse> = "send"

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

// Permissive CORS so the browser demo can call the endpoint from any origin.
let corsHeaders = () =>
  Dict.fromArray([
    ("content-type", "application/json"),
    ("access-control-allow-origin", "*"),
    ("access-control-allow-methods", "GET,OPTIONS"),
    ("access-control-allow-headers", "*"),
  ])

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
    if indexName == "" || q == "" {
      {statusCode: 200, headers: corsHeaders(), body: "[]"}
    } else {
      let client = makeLocationClient()
      let resp = await client->send(
        makeSearchPlaceIndexForTextCommand({indexName, text: q, maxResults: 5}),
      )
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
                Dict.fromArray([
                  ("label", JSON.Encode.string(label)),
                  ("lat", JSON.Encode.float(lat)),
                  ("lng", JSON.Encode.float(lng)),
                ])->JSON.Encode.object,
              )
            | _ => None
            }
          | None => None
          }
        )
      {
        statusCode: 200,
        headers: corsHeaders(),
        body: results->JSON.Encode.array->JSON.stringify,
      }
    }
  } catch {
  | exn =>
    Console.error2("Geocoder: search failed", exn)
    {statusCode: 200, headers: corsHeaders(), body: "[]"}
  }
}
