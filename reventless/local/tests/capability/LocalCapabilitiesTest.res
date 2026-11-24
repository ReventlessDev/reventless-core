open JestGlobals

// The local platform's answer to "what do you provision", and the warning a
// plugin gets for declaring more. Read off the same refs the slices are handed,
// so the two cannot disagree.

let declared = [
  ("Geocoding", "GeocodeAddress"),
  ("Messaging", "SendNotification"),
  ("IdentityProvider", "CreateAccount"),
]

let reset = () => {
  LocalCapabilities.unregisterGeocoder()
  LocalCapabilities.registerMessagingSender("")
  LocalCapabilities.registerIdentityProvider(Reventless.Capabilities.none.identityProvider)
}

describe("LocalCapabilities.unmetWarning", () => {
  testSync("a bare platform provisions nothing, and the warning names each need once", () => {
    reset()
    expect(LocalCapabilities.provisioned())->toEqual([
      Reventless.CapabilityNeed.Stash,
      Reventless.CapabilityNeed.PersonCheck,
    ])
    let message = LocalCapabilities.unmetWarning(~declared)->Option.getOr("")
    expect(message->String.includes("Geocoding (GeocodeAddress)"))->toBe(true)
    expect(message->String.includes(".reventless/places.yaml"))->toBe(true)
    expect(message->String.includes("Capability_Messaging_Log.make()"))->toBe(true)
    expect(message->String.includes("Capability_IdentityProvider_AccountStore.make()"))->toBe(true)
  })

  testSync("a registered provider leaves the warning", () => {
    reset()
    LocalCapabilities.registerMessagingSender("Shop <shop@example.test>")
    LocalCapabilities.registerIdentityProvider(
      Capability_IdentityProvider_AccountStore.make(~path="/nonexistent/accounts.yaml", ()),
    )
    expect(LocalCapabilities.provisioned())->toEqual([
      Reventless.CapabilityNeed.Messaging,
      IdentityProvider,
      Stash,
      PersonCheck,
    ])
    let message = LocalCapabilities.unmetWarning(~declared)->Option.getOr("")
    expect(message->String.includes("Messaging"))->toBe(false)
    expect(message->String.includes("IdentityProvider"))->toBe(false)
    expect(message->String.includes("Geocoding"))->toBe(true)
    reset()
  })

  testSync("a places file provisions geocoding", () => {
    reset()
    LocalCapabilities.registerGeocoder(Capability_Geocoding_Places.search([]))
    expect(LocalCapabilities.provisioned())->toEqual([
      Reventless.CapabilityNeed.Geocoding,
      Stash,
      PersonCheck,
    ])
    let message = LocalCapabilities.unmetWarning(~declared)->Option.getOr("")
    expect(message->String.includes("Geocoding"))->toBe(false)
    reset()
  })

  testSync("a plugin declaring nothing gets no warning", () => {
    reset()
    expect(LocalCapabilities.unmetWarning(~declared=[]))->toEqual(None)
  })
})

describe("Capability_Messaging_Log.senderFor", () => {
  // A root that names its app sends as that app, marked local, from an address that cannot
  // resolve; one that names none keeps the platform's own sender.
  testSync("an app's mail says whose it is", () => {
    expect(Capability_Messaging_Log.senderFor(~appName="Amperia"))->toEqual((
      "Amperia (local)",
      "notifications@amperia.test",
    ))
    expect(Capability_Messaging_Log.senderFor(~appName="Green Fields"))->toEqual((
      "Green Fields (local)",
      "notifications@green-fields.test",
    ))
  })
})
