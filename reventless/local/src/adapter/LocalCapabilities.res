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

// Refusing until a root provides one: the seam exists so a deployment can be
// asked what it provisions, and answering `Unavailable` leaves the work queued
// and visible instead of recording a verdict against a person who has done
// nothing wrong.
let identityProviderRef = ref(Reventless.Capabilities.none.identityProvider)

/** Provision the identity provider. Called by `makePlatform` from the handle a
    root declared, `Capability_IdentityProvider_UserStore.make()`. */
let registerIdentityProvider = (provider: Reventless.IdentityProvider.t) =>
  identityProviderRef := provider

/** What this platform provisions, in the terms a plugin declares its needs:
    read off the same refs `capabilities()` reads, so it cannot disagree with
    what a slice is handed. Geocoding is never here — no local geocoder exists. */
let provisioned = (): array<Reventless.CapabilityNeed.t> =>
  [
    messagingSenderRef.contents == "" ? [] : [Reventless.CapabilityNeed.Messaging],
    identityProviderRef.contents.operations == []
      ? []
      : [Reventless.CapabilityNeed.IdentityProvider],
    // Always: an in-memory stash needs nothing a root could fail to provide.
    [Reventless.CapabilityNeed.Stash],
  ]->Array.flat

/**
The warning for a plugin declaring needs this platform does not provision, or
`None` when every need is met.

A warning where the AWS deploy refuses, and the difference is deliberate: no
local geocoder exists, so a refusal would stop every plugin carrying the
geocoding trait from running locally at all. What the developer loses without
this is the explanation — the slice's items stay retried and nothing says why.
*/
let unmetWarning = (~declared: array<(string, string)>): option<string> =>
  switch Reventless.CapabilityNeed.unmet(~declared, ~provisioned=provisioned()) {
  | [] => None
  | missing =>
    Some(
      Reventless.CapabilityNeed.unmetMessage(missing) ++
      missing
      ->Array.map(u =>
        switch u.need {
        | Geocoding => `\n  Geocoding has no local provider; the slice's items are retried and stay queued.`
        | Messaging =>
          `\n  Messaging is \`Capability_Messaging_Log.make()\`, passed to the platform as ` ++ `\`~messagingSender\`.`
        | IdentityProvider =>
          `\n  IdentityProvider is \`Capability_IdentityProvider_UserStore.make()\`, passed to the ` ++ `platform as \`~identityProvider\`.`
        // Never unmet here: the local platform always provisions one.
        | Stash => ``
        }
      )
      ->Belt.Set.String.fromArray
      ->Belt.Set.String.toArray
      ->Array.join(""),
    )
  }

// One stash for the process: the door that puts and the slice that takes both run
// here, and a stash per call would hand the slice an empty one.
let stash = ref(ReventlessCore.Stash_Memory_Backend.make())

/** A fresh stash, for a test that must not see another's values. */
let resetStash = () => stash := ReventlessCore.Stash_Memory_Backend.make()

let capabilities = (): Reventless.Capabilities.t => {
  geocode: Reventless.Capabilities.none.geocode,
  messaging: ReventlessCore.Messaging_Log_Backend.provider(~sender=messagingSenderRef.contents),
  identityProvider: identityProviderRef.contents,
  secrets: ReventlessCore.Secrets_Node_Backend.provider,
  stash: stash.contents,
}
