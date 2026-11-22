// What the local platform hands a slice's `translate`.
//
// Geocoding answers only for the places `.reventless/places.yaml` lists
// (`Capability_Geocoding_Places`); a real place index is an account and a bill.
// Without the file, and for any address it does not name, `geocode` reports
// `Unavailable`, which `translate` maps to a retryable `Error`: the items stay
// queued, which is true, instead of being written off as unresolvable addresses.
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
    root declared, `Capability_IdentityProvider_AccountStore.make()`. */
let registerIdentityProvider = (provider: Reventless.IdentityProvider.t) =>
  identityProviderRef := provider

// No geocoder until a places file is loaded.
let geocodeRef = ref(None)

/** Provision geocoding from the places a file lists. Called by `makePlatform`. */
let registerGeocoder = (search: Reventless.Geocoding.search) => geocodeRef := Some(search)

/** Back to no geocoder, for a start that finds no places file. */
let unregisterGeocoder = () => geocodeRef := None

// English until a root declares its languages: a complete answer, not a gap.
let textRef = ref(Reventless.Text.sourceOnly)

/** Write to recipients in the declared languages. Called by `makePlatform` from the root's
    `i18n` declaration. */
let registerText = (text: Reventless.Text.t) => textRef := text

/** What this platform provisions, in the terms a plugin declares its needs:
    read off the same refs `capabilities()` reads, so it cannot disagree with
    what a slice is handed. */
let provisioned = (): array<Reventless.CapabilityNeed.t> =>
  [
    geocodeRef.contents->Option.isNone ? [] : [Reventless.CapabilityNeed.Geocoding],
    messagingSenderRef.contents == "" ? [] : [Reventless.CapabilityNeed.Messaging],
    identityProviderRef.contents.operations == []
      ? []
      : [Reventless.CapabilityNeed.IdentityProvider],
    // Always: an in-memory stash needs nothing a root could fail to provide.
    [Reventless.CapabilityNeed.Stash],
    // Always: the local check passes everyone.
    [Reventless.CapabilityNeed.PersonCheck],
  ]->Array.flat

/**
The warning for a plugin declaring needs this platform does not provision, or
`None` when every need is met.

A warning where the AWS deploy refuses, and the difference is deliberate: a
places file is optional, so a refusal would stop every plugin carrying the
geocoding trait from running locally without one. What the developer loses without
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
        | Geocoding => `\n  Geocoding is \`.reventless/places.yaml\`, a list of places with their points; without it the slice's items are retried and stay queued.`
        | Messaging =>
          `\n  Messaging is \`Capability_Messaging_Log.make()\`, passed to the platform as ` ++ `\`~messagingSender\`.`
        | IdentityProvider =>
          `\n  IdentityProvider is \`Capability_IdentityProvider_AccountStore.make()\`, passed to the ` ++ `platform as \`~identityProvider\`.`
        // Never unmet here: the local platform always provisions one.
        | Stash | PersonCheck => ``
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

// The things a translation tells: the running stand-ins once one registers here,
// otherwise not reachable, as a real thing that is offline.
let devicesRef = ref(Reventless.Devices.unreachable(~reason="no stand-in is running"))

/** The devices provider translations tell things through: the running stand-ins. */
let registerDevices = (devices: Reventless.Devices.t) => devicesRef := devices

/** Back to not reachable, for when the stand-ins stop. */
let unregisterDevices = () =>
  devicesRef := Reventless.Devices.unreachable(~reason="no stand-in is running")

let capabilities = (): Reventless.Capabilities.t => {
  geocode: geocodeRef.contents->Option.getOr(Reventless.Capabilities.none.geocode),
  messaging: ReventlessCore.Messaging_Log_Backend.provider(~sender=messagingSenderRef.contents),
  identityProvider: identityProviderRef.contents,
  secrets: ReventlessCore.Secrets_Node_Backend.make(~fingerprintKey=LocalFingerprintKey.get),
  stash: stash.contents,
  text: textRef.contents,
  devices: devicesRef.contents,
  selfRegistrationInitially: LocalSelfRegistration.initially(),
  // Passes: the one signing up on a laptop is the developer, and no widget is needed.
  personCheck: Reventless.PersonCheck.alwaysPasses,
}
