/**
The platform capabilities a slice's `translate` is handed.

A plugin is provider-agnostic: it depends on `reventless-spec`, never on
`reventless-aws`, so it cannot name Amazon Location — and it should not want to.
What it can do is receive a function that geocodes, and let whoever assembled the
runtime decide what is on the other end. The same capability a client reaches
through a GraphQL field, plugin code reaches through here. (The object store has
only the client half so far — `Upload_Presign`; `Offload.resolve(~fetch)` has no
injected caller yet, and the accessor for it belongs in this record.)

Injected rather than looked up, and required rather than optional, because the
alternative is a slot filled at cold start that nothing enforces: ES modules
evaluate imports before the importing module's body, so "the entry point runs
first" is an assumption a bundling change can quietly break. A missing argument
does not compile; an unfilled slot fails on the first real address, in
production.

**A record, not a widening argument list.** Adding a capability later changes
this type, which breaks the handful of places that *construct* it — the
platforms, which is exactly where a new capability has to be wired anyway — and
leaves every `translate` reading `capabilities.geocode` untouched.
*/
type t = {
  /** Turn an address into ranked candidates. See `Geocoding.search`. */
  geocode: Geocoding.search,
  /** Send a message to a person, and say which channels this deployment can
      attempt at all. See `Messaging.provider`. */
  messaging: Messaging.provider,
}

/**
The capability set of a platform that provisions nothing.

Every capability here answers `Unavailable`, which is a *modelled* outcome:
`translate` maps it to `Error`, the item is retried and the sweep surfaces it.
That is the behaviour wanted for a deployment that simply has no geocoder — the
work stays queued and visible rather than being written off as a verdict on the
address, which is what `NoMatch` would mean.

Named so that a platform passing it is making a statement rather than filling in
a blank.
*/
let none: t = {
  geocode: async (~text as _) => Error(Unavailable("no geocoder is configured for this platform")),
  // `channels: []` and a retryable `send` say two different true things, and both
  // are needed. The empty list is what a deploy gate reads and what a preference
  // centre renders — offering a channel nothing can deliver on would collect a
  // subscription that never arrives. The send stays `Unavailable` rather than
  // `UnsupportedChannel` because a caller that got this far is looking at a
  // deployment gap, not at a fact about the recipient, and abandoning the message
  // would record the second.
  messaging: {
    channels: [],
    send: async (~recipient as _, ~message as _) => Error(
      Unavailable("no messaging provider is configured for this platform"),
    ),
  },
}
