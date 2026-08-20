/**
Turning an address into a point, and deciding whether to believe the answer.

The transport is provider-specific and lives with its provider. What is here is
provider-neutral: the shape of an answer, the two ways a lookup fails, and the
confidence rule — decided once, so no transport invents its own.
*/

/** One candidate a geocoder returned. */
type candidate = {
  /** The provider's canonical rendering of the address it matched. */
  label: string,
  point: GeoPoint.t,
  /** How well this matches, 0…1. `None` when the provider does not score, which
      `confidentMatch` declines rather than reading as high. */
  relevance: option<float>,
}

/** Why a lookup produced no usable point. Two constructors because the retry
    decision turns on the distinction: an outage must not become a verdict. */
type failure =
  | /** The provider could not be reached, or refused the call. Retry. */
  Unavailable(string)
  | /** The provider answered, and had nothing for this text. Do not retry. */
  NoMatch

/**
The port a caller reaches a geocoder through, so swapping the implementation is a
change of supplier rather than of call site.

`~text` is unnormalised; the provider's canonical rendering comes back as
`candidate.label`.
*/
type search = (~text: string) => promise<result<array<candidate>, failure>>

/**
The default confidence floor, measured against Amazon Location's Esri index:
correct matches scored ≥ 0.988, wrong ones 0.913…0.958, so `0.97` sits in the gap.

Provider-calibrated, which is why it is a labelled argument — a geocoder scoring
on a different curve needs its own pair.
*/
let defaultMinRelevance = 0.97

/** How close the runner-up may come before the answer is ambiguous. Small, because
    real ambiguity shows up as a tie; a wide margin only rejects clear winners. */
let defaultAmbiguityMargin = 0.01

/** The confidence decision with the reason attached, for a caller that reports
    the outcome rather than acting on it. */
type assessment =
  | Confident(candidate)
  | NoCandidates
  | /** Unscored is not a low score, and must not read as a high one. */
  Unscored(candidate)
  | LowRelevance({top: candidate, score: float, floor: float})
  | /** Several matches about equally well. */
  Ambiguous({top: candidate, runnerUp: candidate, margin: float})

/** The confidence rule, stated once. Everything else here derives from it. */
let assess = (
  candidates: array<candidate>,
  ~minRelevance: float=defaultMinRelevance,
  ~ambiguityMargin: float=defaultAmbiguityMargin,
): assessment =>
  switch candidates->Array.get(0) {
  | None => NoCandidates
  | Some(top) =>
    switch top.relevance {
    | None => Unscored(top)
    | Some(topScore) =>
      if topScore < minRelevance {
        LowRelevance({top, score: topScore, floor: minRelevance})
      } else {
        switch candidates->Array.get(1) {
        | Some(runnerUp) =>
          switch runnerUp.relevance {
          | Some(runnerUpScore) if topScore -. runnerUpScore < ambiguityMargin =>
            Ambiguous({top, runnerUp, margin: ambiguityMargin})
          | _ => Confident(top)
          }
        | None => Confident(top)
        }
      }
    }
  }

/**
The one candidate confident enough to store, or `None` — which means "ask a
human", not "no result". Declines a top scoring below `minRelevance` and a
runner-up within `ambiguityMargin`. `assess` says which rule declined.
*/
let confidentMatch = (
  candidates: array<candidate>,
  ~minRelevance: float=defaultMinRelevance,
  ~ambiguityMargin: float=defaultAmbiguityMargin,
): option<candidate> =>
  // Listed rather than `_`, so a new case must be decided here.
  switch candidates->assess(~minRelevance, ~ambiguityMargin) {
  | Confident(top) => Some(top)
  | NoCandidates
  | Unscored(_)
  | LowRelevance(_)
  | Ambiguous(_) =>
    None
  }
