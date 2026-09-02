// What the local platform hands a slice's `translate`.
//
// No geocoder: the local platform provisions none (a place index is an account
// and a bill), so `Capabilities.none`'s `geocode` reports `Unavailable`, which
// `translate` maps to a retryable `Error` and the sweep surfaces. A dev running a
// geocoding slice sees its items stay queued, which is true, instead of seeing
// them written off as unresolvable addresses, which would not be.
//
// Messaging is provisioned when a root asks for it, exactly as on AWS: a
// `Capability_Messaging_Log.make()` handle passed as `~messagingSender`
// reaches `registerMessagingSender` and the transport becomes the provider. A root
// that passes nothing keeps the old answer — an empty sender yields no channels
// and a retryable `Unavailable`, which is what an unprovisioned platform is.
//
// The sender is a ref read per call rather than a value captured once, mirroring
// the Lambda side: there `capabilities()` re-reads `MESSAGING_EMAIL_SENDER` on
// every invocation so a reconfigured function needs no cold start. Here it means
// the order of `makePlatform`'s work is not a thing to get right.

let messagingSenderRef = ref("")

/** Provision the messaging capability. Called by `makePlatform` from the handle
    a root declared — the local half of the seam whose AWS half is
    `PluginRuntime_Builder.registerMessagingSender`. */
let registerMessagingSender = (sender: string) => messagingSenderRef := sender

let capabilities = (): Reventless.Capabilities.t => {
  geocode: Reventless.Capabilities.none.geocode,
  messaging: ReventlessCore.Messaging_Log_Backend.provider(~sender=messagingSenderRef.contents),
}
