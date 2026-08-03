// The plugin's geocoding client.
//
// A plugin is provider-agnostic — it cannot reach `ReventlessAws` and should not
// know that Amazon Location is what answers. So this talks HTTP to whatever
// endpoint the deployment configured and speaks the framework's provider-neutral
// vocabulary (`Reventless.Geocoding`) on both sides.
//
// The endpoint's contract, which is what makes an unattended caller possible:
// `200` with a (possibly empty) array is an answer, and any other status is the
// service failing to give one. The distinction is the whole reason this returns
// `result` rather than a list — see `Reventless.Geocoding.failure`.

@val external fetch: (string, 'options) => promise<'response> = "fetch"

type response = {ok: bool, status: int}
@send external json: response => promise<JSON.t> = "json"

@val external encodeURIComponent: string => string = "encodeURIComponent"

// `process.env` without a Node binding — a plugin depends on neither
// rescript-node nor any provider package.
type processT = {env: dict<string>}
@val external process: processT = "process"

let endpoint = () =>
  switch process.env->Dict.get("GEOCODER_ENDPOINT") {
  | Some("") | None => None
  | Some(v) => Some(v)
  }

// One candidate off the wire. A row missing a coordinate, or carrying one
// outside the valid ranges, is dropped rather than propagated — it cannot be
// stored, and one bad row should not lose the good ones beside it.
let decodeCandidate = (json: JSON.t): option<Reventless.Geocoding.candidate> =>
  switch json->JSON.Decode.object {
  | None => None
  | Some(o) =>
    switch (
      o->Dict.get("lat")->Option.flatMap(JSON.Decode.float),
      o->Dict.get("lng")->Option.flatMap(JSON.Decode.float),
    ) {
    | (Some(lat), Some(lng)) =>
      switch Reventless.GeoPoint.make(~lat, ~lng) {
      | Ok(point) =>
        Some({
          Reventless.Geocoding.label: o
          ->Dict.get("label")
          ->Option.flatMap(JSON.Decode.string)
          ->Option.getOr(""),
          point,
          relevance: o->Dict.get("relevance")->Option.flatMap(JSON.Decode.float),
        })
      | Error(_) => None
      }
    | _ => None
    }
  }

let search = async (~text: string): result<
  array<Reventless.Geocoding.candidate>,
  Reventless.Geocoding.failure,
> => {
  let trimmed = text->String.trim
  switch endpoint() {
  | None => Error(Unavailable("no geocoder endpoint configured (GEOCODER_ENDPOINT unset)"))
  | Some(_) if trimmed == "" =>
    // An empty query was never going to match; asking would spend a request to
    // be told so.
    Error(NoMatch)
  | Some(base) =>
    let url = `${base}?q=${encodeURIComponent(trimmed)}`
    switch await fetch(url, {"method": "GET"}) {
    | response =>
      if !response.ok {
        Error(Unavailable(`geocoder responded ${response.status->Int.toString}`))
      } else {
        switch await response->json {
        | body =>
          let candidates =
            body->JSON.Decode.array->Option.getOr([])->Array.filterMap(decodeCandidate)
          candidates->Array.length == 0 ? Error(NoMatch) : Ok(candidates)
        | exception _ => Error(Unavailable("geocoder returned a body that is not JSON"))
        }
      }
    | exception exn =>
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      Error(Unavailable(msg))
    }
  }
}
