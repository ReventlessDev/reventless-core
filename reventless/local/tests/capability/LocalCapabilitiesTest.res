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
  LocalCapabilities.registerMessagingSender("")
  LocalCapabilities.registerIdentityProvider(Reventless.Capabilities.none.identityProvider)
}

describe("LocalCapabilities.unmetWarning", () => {
  testSync("a bare platform provisions nothing, and the warning names each need once", () => {
    reset()
    expect(LocalCapabilities.provisioned())->toEqual([])
    let message = LocalCapabilities.unmetWarning(~declared)->Option.getOr("")
    expect(message->String.includes("Geocoding (GeocodeAddress)"))->toBe(true)
    expect(message->String.includes("Capability_Messaging_Log.make()"))->toBe(true)
    expect(message->String.includes("Capability_IdentityProvider_UserStore.make()"))->toBe(true)
  })

  testSync("a registered provider leaves the warning", () => {
    reset()
    LocalCapabilities.registerMessagingSender("Shop <shop@example.test>")
    LocalCapabilities.registerIdentityProvider(
      Capability_IdentityProvider_UserStore.make(~path="/nonexistent/users.yaml", ()),
    )
    expect(LocalCapabilities.provisioned())->toEqual([
      Reventless.CapabilityNeed.Messaging,
      IdentityProvider,
    ])
    let message = LocalCapabilities.unmetWarning(~declared)->Option.getOr("")
    expect(message->String.includes("Messaging"))->toBe(false)
    expect(message->String.includes("IdentityProvider"))->toBe(false)
    expect(message->String.includes("Geocoding"))->toBe(true)
    reset()
  })

  testSync("a plugin declaring nothing gets no warning", () => {
    reset()
    expect(LocalCapabilities.unmetWarning(~declared=[]))->toEqual(None)
  })
})
