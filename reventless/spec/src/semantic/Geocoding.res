/**
Turning an address into a point, and deciding whether to believe the answer.

The *transport* is provider-specific — Amazon Location, a self-hosted Nominatim,
a vendor's HTTP API — and lives with its provider. What lives here is everything
that is the same regardless of who answers: the shape of an answer, the two ways
a lookup can fail, and the rule for when a ranked list is confident enough to
write a coordinate into an event log.

That split matters because the confidence rule is the part that is easy to get
wrong and expensive to get wrong twice. A caller that re-derives it — takes
`results[0]` because the list was ranked — produces a plausible marker in the
wrong region, drawn without an error anywhere. Deciding it once, here, is what
stops each transport inventing its own answer.
*/

/** One candidate a geocoder returned. */
type candidate = {
  /** The provider's canonical rendering of the address it matched. */
  label: string,
  point: GeoPoint.t,
  /**
  How well this result matches the query, 0…1.

  `None` when the provider does not score its results. That is not the same as a
  low score and must not be read as a high one — `confidentMatch` declines it,
  because an unscored list cannot support an unattended decision.
  */
  relevance: option<float>,
}

/**
Why a lookup produced no usable point.

Two constructors rather than one message because the caller's retry decision
turns on exactly this distinction, and a `switch` is the only form of it that
cannot be got wrong. A translator that cannot tell "no such address" from "the
service is down" turns one outage into a permanent verdict on every address in
flight.
*/
type failure =
  | /** The provider could not be reached, or refused the call. Retry. */
  Unavailable(string)
  | /** The provider answered, and had nothing for this text. Do not retry. */
  NoMatch

/** The default confidence floor. A starting point, not a finding — the first
    real corpus of addresses is what should set it. */
let defaultMinRelevance = 0.8

/**
The one candidate confident enough to store, or `None`.

Two ways to be unsure, and both decline:

- the top candidate scores below `minRelevance` — the provider matched
  something, loosely;
- the runner-up scores within `ambiguityMargin` of the top — the provider
  matched several things about equally well, which is what a bare town name
  does.

`None` means "ask a human", not "no result". The candidates are still there for
a caller that wants to show them.
*/
let confidentMatch = (
  candidates: array<candidate>,
  ~minRelevance: float=defaultMinRelevance,
  ~ambiguityMargin: float=0.1,
): option<candidate> =>
  switch candidates->Array.get(0) {
  | None => None
  | Some(top) =>
    switch top.relevance {
    | None => None
    | Some(topScore) =>
      if topScore < minRelevance {
        None
      } else {
        switch candidates->Array.get(1)->Option.flatMap(c => c.relevance) {
        | Some(runnerUp) if topScore -. runnerUp < ambiguityMargin => None
        | _ => Some(top)
        }
      }
    }
  }
