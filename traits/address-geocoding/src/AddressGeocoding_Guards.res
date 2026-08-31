/**
The graft's decision rules, compiled once and called by every host: an answer for
a subject the entity has moved off is stale, a redelivered answer is a no-op, and
a verdict already recorded for the current subject is not recorded twice.

The host keeps its own state — an aggregate's is snapshotted, so a trait-owned
record in it would make every release that reshapes it a migration — and builds a
`resolution` per call from the fields it already holds. What comes back is a
verdict on one command, which the host names in its own event.
*/

/** The three fields the rules read, as the host holds them. Its invariant, which
    every host arm must preserve: `resolvedFrom` is `None` or equal to `subject`. */
type resolution = {
  subject: string,
  location: option<Reventless.GeoPoint.t>,
  resolvedFrom: option<string>,
}

type verdict = Append | Ignore

/** A subject the entity already has changes nothing; a different one reopens the
    question, because the host's fold drops what was resolved for the old one. */
let onSubjectUpdate = (r, ~subject) => subject == r.subject ? Ignore : Append

/**
A client supplying both halves. Idempotent only when *both* already match: the
same subject with a different point is a pin correction, and swallowing it would
lose the one edit a human came to make.
*/
let onSuppliedPair = (r, ~subject, ~location) =>
  subject == r.subject && r.location == Some(location) ? Ignore : Append

/**
A point reported by the geocoder. Stale when it answers a subject since changed —
applying it would pin the new subject at the old one's point with nothing to say
the two disagree. Redelivery matters because commands arrive at least once and the
slice re-publishes on every heartbeat until its TODO clears.
*/
let onLocationReport = (r, ~location, ~resolvedFrom) =>
  if resolvedFrom != r.subject {
    Ignore
  } else if r.location == Some(location) && r.resolvedFrom == Some(resolvedFrom) {
    Ignore
  } else {
    Append
  }

/** The same two guards for the verdict: `resolvedFrom` already naming the subject
    is the record that it was tried and found wanting. */
let onUnresolvableReport = (r, ~subject) =>
  if subject != r.subject {
    Ignore
  } else if r.resolvedFrom == Some(subject) {
    Ignore
  } else {
    Append
  }
