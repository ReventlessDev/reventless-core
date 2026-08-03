// Amazon Location as a geocoding transport for unattended callers.
//
// Policy — what a candidate is, the two ways a lookup fails, and when a ranked
// list is confident enough to store — lives in `Reventless.Geocoding`, shared
// with every other transport. This module only knows how to ask AWS and how to
// turn its answer into that vocabulary.
//
// The public Function URL handler next door answers `200 []` for a genuine
// no-match and `502 []` for a service failure, because a browser search box must
// degrade quietly while a translator must not. This module makes the same
// distinction at the source, for a caller that can reach the SDK directly.
//
// Runtime-pure: no Pulumi import, so it can be bundled into a Lambda entry point
// without dragging deploy-time modules into the cold-start graph.

module Search = AwsSdk.Location.SearchPlaceIndexForTextCommand

/**
Geocode one address.

`Ok([])` is deliberately unreachable — an empty result set is `Error(NoMatch)`,
because "the call worked and the answer is nothing" is a different fact from
"the call worked", and the caller has to act differently on it.

Candidates come back in the provider's ranking order, unfiltered. Choosing among
them is `Reventless.Geocoding.confidentMatch`'s job.
*/
let search = async (~indexName: string, ~text: string, ~maxResults: int=5): result<
  array<Reventless.Geocoding.candidate>,
  Reventless.Geocoding.failure,
> => {
  let trimmed = text->String.trim
  if indexName == "" {
    Error(Unavailable("no place index configured (PLACE_INDEX_NAME unset)"))
  } else if trimmed == "" {
    // Not a service failure and not a service verdict — an empty query was never
    // going to match, and asking would spend a request to be told so.
    Error(NoMatch)
  } else {
    switch await Search.send(Search.make({indexName, text: trimmed, maxResults})) {
    | resp =>
      let candidates =
        resp.results
        ->Option.getOr([])
        ->Array.filterMap(r =>
          switch r.place {
          | None => None
          | Some(place) =>
            // `[lng, lat]` — RFC 7946 order, converted here and nowhere else.
            switch place.geometry->Option.flatMap(g => g.point) {
            | Some(pt) if pt->Array.length >= 2 =>
              switch Reventless.GeoPoint.make(
                ~lat=pt->Array.getUnsafe(1),
                ~lng=pt->Array.getUnsafe(0),
              ) {
              | Ok(point) =>
                Some({
                  Reventless.Geocoding.label: place.label->Option.getOr(""),
                  point,
                  relevance: r.relevance,
                })
              // A coordinate that fails the range check is dropped rather than
              // propagated: it cannot be stored, and one bad row should not lose
              // the good ones beside it.
              | Error(_) => None
              }
            | _ => None
            }
          }
        )
      candidates->Array.length == 0 ? Error(NoMatch) : Ok(candidates)
    | exception exn =>
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      Error(Unavailable(msg))
    }
  }
}
