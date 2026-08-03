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

/**
The port a caller reaches a geocoder through.

Everything above says what an answer looks like; this says how one is asked for.
Written down as a type before anything is injected against it, so that swapping
the implementation underneath a caller is a change of *supplier* rather than a
change of call site: whatever eventually hands a translator its geocoder — an
HTTP client reading an endpoint out of its environment, a provider SDK called
directly — has to satisfy this, and the `await search(~text=…)` in the caller
does not move.

`~text` is the address as a human typed it, unnormalised. Normalising it is the
provider's job, and its canonical rendering comes back as `candidate.label`.
*/
type search = (~text: string) => promise<result<array<candidate>, failure>>

/**
The default confidence floor, calibrated against Amazon Location's Esri index.

Measured, not guessed — and the measurement moved it a long way. Esri does not
spread its scores over 0…1: everything it is willing to return at all lands in
roughly 0.9…1.0, so a floor of `0.8` admitted almost every answer and left the
ambiguity margin doing all the work. The separation is up at the top of the
range instead — in a 24-address corpus the correct pinpoint matches scored
≥ 0.988 while the wrong ones (a misspelling resolved to the wrong state, a
street name matched to a different street in the right city) scored 0.913…0.958.

`0.97` sits in that gap. The wider consequence is that these numbers are
*provider-calibrated* even though everything else in this module is
provider-neutral, which is exactly why both are labelled arguments: a geocoder
that scores on a different curve needs its own pair, and the defaults are the
Esri answer rather than a universal one.
*/
let defaultMinRelevance = 0.97

/**
How close the runner-up may come before the answer is called ambiguous.

Deliberately small, for the same reason the floor is large. Genuine ambiguity in
Esri shows up as a *tie* — "Springfield" returns five states at exactly 1.0,
"221B Baker" five towns at exactly 0.8222 — not as a near miss. A wide margin
does not catch more of those; it only starts rejecting clear winners, because a
correct match at 0.991 routinely has a plausible runner-up at 0.962.
*/
let defaultAmbiguityMargin = 0.01

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
  ~ambiguityMargin: float=defaultAmbiguityMargin,
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
