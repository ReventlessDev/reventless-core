// Local geocode resolver — the *client* door of the geocoding capability (D9 half
// 2) on the dev platform. Registers `Query.geocode` on the domain server the same
// way `LocalUploadResolvers` registers `Upload_Presign`, which is the local analogue
// of adding the field to `domainBaseFragment` on AWS.
//
// This closes a dev-experience gap: before it, `config.geocoderEndpoint` was unset
// in local dev, so the map picker's search box did not render at all and the input
// was click-to-place only. With this door registered, address search works in dev.
//
// The dev platform provisions no real geocoder — `LocalCapabilities` keeps the
// *unattended* slice path at `Capabilities.none`, and the two doors are
// independent. This browser door is a deterministic stub: a non-empty query
// resolves to one candidate whose point is a stable function of the query text, so
// a search places a pin, in the same spot every time, with no network call or API
// key. The coordinates are placeholders — echoed back beside the query as the label
// — not a real geocode. An empty query yields no results, matching the AWS door and
// the browser's cleared-input case.

// A stable, in-range `(lat, lng)` derived from the query text: fold the character
// codes into one number and map it into safe coordinate bands. Deterministic, so a
// dev search is reproducible across reloads.
let stubPoint = (text: string): (float, float) => {
  let sum = ref(0)
  for i in 0 to text->String.length - 1 {
    let code = text->String.codePointAt(i)->Option.getOr(0)
    sum := sum.contents + code * (i + 1)
  }
  let n = sum.contents
  let lat = mod(n, 120)->Int.toFloat -. 60.0 // −60 … 59
  let lng = mod(n / 7, 240)->Int.toFloat -. 120.0 // −120 … 119
  (lat, lng)
}

let register = (server: ReventlessGraphqlServer.GraphQL_ServerInstance.t): unit => {
  let resolvers = Dict.make()
  resolvers->Dict.set("geocode", async (_root, args, _ctx): JSON.t => {
    let obj = args->JSON.Decode.object->Option.getOr(Dict.make())
    let text =
      obj
      ->Dict.get("text")
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr("")
      ->String.trim
    if text == "" {
      JSON.Encode.array([])
    } else {
      let (lat, lng) = stubPoint(text)
      let candidate =
        Dict.fromArray([
          ("label", JSON.Encode.string(text)),
          ("lat", JSON.Encode.float(lat)),
          ("lng", JSON.Encode.float(lng)),
          ("relevance", JSON.Encode.float(1.0)),
        ])->JSON.Encode.object
      JSON.Encode.array([candidate])
    }
  })
  server.registerTypes(~sdlTypes=ReventlessCore.Platform_AdminApi.geocodeTypes)
  server.registerQueries(
    ~sdlFields=ReventlessCore.Platform_AdminApi.geocodeQueryFields,
    ~resolvers,
  )
}
