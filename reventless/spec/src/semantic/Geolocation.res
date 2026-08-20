/**
A geocoder's answer as one value; `Geocoding`'s return type.

Three arms rather than `option<GeoPoint.t>`, whose `None` means both "has not run"
and "ran and failed". Emitted as a GraphQL union (see `Reventless.TaggedUnion`).
Replacing a point/status/note trio with it is wire-breaking.
*/

@schema
type t =
  | /** `requestedFor` is the address asked about, so a stale answer is detectable. */
  Pending({requestedFor: string})
  | Located({point: GeoPoint.t})
  | /** Answered, with nothing storable unattended. A verdict for a human. */
  Unresolvable({reason: string})

/** Adds the two markers the shape cannot carry: the semantic, and the union name
    the SDL and the `__typename` stamp share. */
let schema: S.t<t> =
  schema->Semantic.mark(~id=Semantic.Id.geolocation)->TaggedUnion.named(~name="Geolocation")

/** The point, when there is one. */
let point = (geolocation: t): option<GeoPoint.t> =>
  switch geolocation {
  | Located({point}) => Some(point)
  | Pending(_) | Unresolvable(_) => None
  }

let isLocated = (geolocation: t): bool => geolocation->point->Option.isSome

/** Why it could not be resolved. `None` for `Pending`, which is still waiting. */
let reason = (geolocation: t): option<string> =>
  switch geolocation {
  | Unresolvable({reason}) => Some(reason)
  | Pending(_) | Located(_) => None
  }

/**
The geolocation a geocoder's answer implies, via `Geocoding.assess`.

`Error(Unavailable(_))` returns `None` — leave the row alone, since an outage
written as a verdict is permanent. Never returns `Pending`. Thresholds are
threaded because they are provider-calibrated.
*/
let ofSearch = (
  ~requestedFor: string,
  ~minRelevance: float=Geocoding.defaultMinRelevance,
  ~ambiguityMargin: float=Geocoding.defaultAmbiguityMargin,
  answer: result<array<Geocoding.candidate>, Geocoding.failure>,
): option<t> =>
  switch answer {
  | Error(Unavailable(_)) => None
  | Error(NoMatch) => Some(Unresolvable({reason: `no match for "${requestedFor}"`}))
  | Ok(candidates) =>
    // Reasons report what came back; the rule that rejected it stays in `assess`.
    switch candidates->Geocoding.assess(~minRelevance, ~ambiguityMargin) {
    | Confident(top) => Some(Located({point: top.point}))
    | NoCandidates => Some(Unresolvable({reason: `no candidates for "${requestedFor}"`}))
    | Unscored(top) =>
      Some(
        Unresolvable({
          reason: `the geocoder returned "${top.label}" for "${requestedFor}" without scoring it, ` ++
          `and an unscored answer cannot be accepted unattended`,
        }),
      )
    | LowRelevance({top, score, floor}) =>
      Some(
        Unresolvable({
          reason: `the best match for "${requestedFor}" was "${top.label}" at relevance ` ++
          `${Float.toString(score)}, below the ${Float.toString(floor)} needed to store one`,
        }),
      )
    | Ambiguous({top, runnerUp}) =>
      Some(
        Unresolvable({
          reason: `"${requestedFor}" matched "${top.label}" and "${runnerUp.label}" ` ++
          `about equally well`,
        }),
      )
    }
  }
