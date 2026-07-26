// AWS Location Service geocoder behind a public Lambda Function URL.
//
// Deploy-time: `make` provisions a CallbackFunction (its handler closure is
// serialized by Pulumi), an IAM execution role scoped to
// `geo:SearchPlaceIndexForText` on the target place index, and a Function URL
// (no auth) so a browser can geocode directly.
//
// Runtime: `handleGeocode` reads a `q` query-string param from the Function URL
// event, calls SearchPlaceIndexForText against the place index named in
// `PLACE_INDEX_NAME`, and returns `[{label, lat, lng}]` as JSON. Any failure
// degrades to an empty array so the caller never sees a hard error.

open PulumiAws

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

// Read an env var at runtime, mapping "" / unset to None.
let getEnv: string => option<string> = %raw(`
  function(k) { var v = process.env[k]; return (v === undefined || v === null || v === "") ? undefined : v; }
`)

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

let handleGeocode = async (event: functionUrlEvent, _context: Lambda.context): response => {
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
  | _ => {statusCode: 200, headers: corsHeaders(), body: "[]"}
  }
}

// ── Deploy-time factory ─────────────────────────────────────────────────────

type serviceOutputs = {
  url: Pulumi.Output.t<string>,
  resources: array<Pulumi.Output.t<string>>,
}

let make = (
  ~placeIndexName: Pulumi.Input.t<string>,
  ~corsOrigins: array<string>=["*"],
  ~opts=?,
): serviceOutputs => {
  let serviceName = "GeocoderService"
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=serviceName,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=serviceName,
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts?,
  )

  // Least-privilege: SearchPlaceIndexForText on the one place index.
  let _policy =
    placeIndexName
    ->Pulumi.Output.fromInput
    ->Pulumi.Output.apply(idx => {
      let arn = `arn:aws:geo:*:*:place-index/${idx}`
      let _ = IAM.RolePolicy.make(
        ~name=`${serviceName}Policy`,
        ~args={
          policy: PolicyDocument.make(
            ~id=`${serviceName}Policy`,
            ~statements=[
              {
                sid: "AllowGeocode",
                effect: Allow,
                actions: Action("geo:SearchPlaceIndexForText"),
                resources: Resource(arn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts?,
      )
    })

  let environment: Lambda.CallbackFunction.Args.functionEnvironment = {
    // CallbackFunction under-types env values as `dict<string>`; Pulumi resolves
    // Output-valued variables at deploy time, so bridge the Input here.
    variables: Dict.fromArray([("PLACE_INDEX_NAME", placeIndexName)])->Obj.magic,
  }

  let lambda = Lambda.CallbackFunction.make(
    ~name=serviceName,
    ~args=Lambda.CallbackFunction.Args.make(
      ~callback=handleGeocode,
      ~role=lambdaRole,
      ~environment,
      ~timeout=30->Pulumi.Input.make,
      ~tags=AWS.Tags.make(
        ~name=serviceName,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Runtime,
        ~scope=Platform,
      ),
    ),
    ~opts?,
  )

  let functionUrl = FunctionUrl.make(
    ~name=`${serviceName}Url`,
    ~args={
      authorizationType: FunctionUrl.None,
      functionName: lambda.name->Pulumi.Output.asInput,
      cors: (
        {
          allowMethods: ["GET"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
          allowOrigins: corsOrigins->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
          allowHeaders: ["*"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
        }: FunctionUrl.cors
      )->Pulumi.Input.make,
    },
    ~opts?,
  )

  {
    url: functionUrl.functionUrl,
    resources: [lambda.arn, functionUrl.functionArn],
  }
}
