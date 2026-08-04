// What the local platform hands a slice's `translate`.
//
// Nothing, today — and that is the honest answer rather than a placeholder. The
// local platform provisions no geocoder (a deployed stack's place index is an
// account and a bill), so `Capabilities.none` reports `Unavailable`, which
// `translate` maps to a retryable `Error` and the sweep surfaces. A dev running
// a geocoding slice sees its items stay queued, which is true, instead of seeing
// them written off as unresolvable addresses, which would not be.
//
// This is the one place to change when local grows a real one — a fixture, a
// stub keyed by address, or Nominatim. Slices reach it through the injected
// record, so nothing in a plugin moves on that day.
let capabilities = () => Reventless.Capabilities.none
