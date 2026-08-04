// Runtime handler for the geocoder's client door — compiled, type-checked, and
// Pulumi-free so it can be shipped as an EntryPoint module
// (`Geocoder_AwsLocation_Resolver` bundles it and attaches it as the platform API's
// `Query.geocode` Lambda data source). Keeping it out of the deploy-time module
// avoids both the serialized-closure SDK skew and a deploy-time Pulumi import
// leaking into the Lambda's cold-start graph.
//
// Invoked by an AppSync resolver, not a Function URL: the platform API's Cognito
// authorizer has already authenticated the caller, so there is no token to decode
// and no anonymous surface. The SDK call, the `[lng, lat]` order and the relevance
// handling all live in `Geocoder_AwsLocation_Backend`, shared with the unattended
// slice path so one module owns the AWS Location call.
//
// Returns the ranked candidates as `[{label, lat, lng, relevance?}]`. A no-match is
// an empty array — a browser search box degrades to "no results". A service failure
// throws, which the resolver's response mapper turns into a GraphQL error rather
// than an empty answer: the client half of D2's status contract, so a browser can
// tell "no such address" from "the geocoder is down" the way the Function URL's
// `200`/`502` split did.

let candidateJson = (c: Reventless.Geocoding.candidate): JSON.t =>
  Dict.fromArray(
    Array.concat(
      [
        ("label", JSON.Encode.string(c.label)),
        ("lat", JSON.Encode.float(c.point.lat)),
        ("lng", JSON.Encode.float(c.point.lng)),
      ],
      switch c.relevance {
      | Some(rel) => [("relevance", JSON.Encode.float(rel))]
      | None => []
      },
    ),
  )->JSON.Encode.object

// Only `text` is read; `ctx.identity` is forwarded by the resolver but the geocoder
// does not scope by caller, so the handler ignores it.
type geocodeArgs = {text?: string}
type appSyncEvent = {arguments?: geocodeArgs}

let handler = async (event: appSyncEvent): array<JSON.t> => {
  let indexName = switch NodeProcess.env->Dict.get("PLACE_INDEX_NAME") {
  | Some("") | None => ""
  | Some(v) => v
  }
  let text = event.arguments->Option.flatMap(a => a.text)->Option.getOr("")
  switch await Geocoder_AwsLocation_Backend.search(~indexName, ~text) {
  | Ok(candidates) => candidates->Array.map(candidateJson)
  // The provider answered and had nothing — a true, final empty answer.
  | Error(NoMatch) => []
  // Misconfigured (no index) or the service failed: throw so `ctx.error` is set and
  // the caller sees an error, never a silent empty list it would read as "no match".
  | Error(Unavailable(msg)) => JsError.throwWithMessage(`geocoder unavailable: ${msg}`)
  }
}
