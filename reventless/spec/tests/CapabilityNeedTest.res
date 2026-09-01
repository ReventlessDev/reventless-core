// The deploy gate's decision, away from Pulumi.
//
// A plugin's declared capability needs travel as strings (a pluginStructure is
// replayed from an event log), and the platform's provisioning evidence is
// whatever the deploy actually handed the slices. This is the rule that turns
// the two into a refusal — the one place where "silently degrades" and "fails
// the deploy" are told apart.

open JestGlobals

describe("CapabilityNeed", () => {
  describe("round trip", () => {
    let all: array<CapabilityNeed.t> = [Geocoding, Messaging]

    testSync("every arm survives toString → fromString", () =>
      expect(all->Array.map(n => n->CapabilityNeed.toString->CapabilityNeed.fromString))->toEqual(
        all->Array.map(n => Some(n)),
      )
    )

    testSync("an unknown name is reported as unknown, not folded into an arm", () =>
      expect(CapabilityNeed.fromString("Telepathy"))->toEqual(None)
    )
  })

  describe("unmet", () => {
    let declared = [("Geocoding", "GeocodeCustomerAddress")]

    testSync("a declared need the platform provisions is met", () =>
      expect(CapabilityNeed.unmet(~declared, ~provisioned=[Geocoding]))->toEqual([])
    )

    testSync("a declared need the platform provisions nothing for is unmet", () =>
      expect(CapabilityNeed.unmet(~declared, ~provisioned=[]))->toEqual([
        ({need: Geocoding, component: "GeocodeCustomerAddress"}: CapabilityNeed.unmet),
      ])
    )

    // The rule that keeps every deployment working today: an unprovisioned
    // capability nobody named is a modelled outcome, not a deploy failure.
    testSync("a plugin that declares nothing is never unmet", () =>
      expect(CapabilityNeed.unmet(~declared=[], ~provisioned=[]))->toEqual([])
    )

    // A newer plugin naming a capability this build has no arm for. Refusing
    // would be a guess about a name this code cannot evaluate.
    testSync("a capability this build does not recognise is skipped", () =>
      expect(
        CapabilityNeed.unmet(~declared=[("Telepathy", "Guess")], ~provisioned=[]),
      )->toEqual([])
    )

    testSync("every declaring component is named, not just the first", () =>
      expect(
        CapabilityNeed.unmet(
          ~declared=[("Geocoding", "GeocodeCustomerAddress"), ("Geocoding", "GeocodeDropOff")],
          ~provisioned=[],
        )->Array.map(u => u.component),
      )->toEqual(["GeocodeCustomerAddress", "GeocodeDropOff"])
    )

    // A platform provisioning one capability and not the other. The arms are
    // independent, and the refusal has to name only the one that is missing —
    // a gate that failed on the provisioned one too would be unfixable.
    testSync("one provisioned capability does not cover another", () =>
      expect(
        CapabilityNeed.unmet(
          ~declared=[("Geocoding", "GeocodeCustomerAddress"), ("Messaging", "SendOrderConfirmation")],
          ~provisioned=[Geocoding],
        ),
      )->toEqual([({need: Messaging, component: "SendOrderConfirmation"}: CapabilityNeed.unmet)])
    )
  })

  describe("unmetMessage", () => {
    let message = CapabilityNeed.unmetMessage([
      ({need: Geocoding, component: "GeocodeCustomerAddress"}: CapabilityNeed.unmet),
    ])

    testSync("names the capability and the component that declared it", () =>
      expect(message->String.includes("Geocoding (GeocodeCustomerAddress)"))->toBe(true)
    )

    // The whole reason this refusal exists: the failure it replaces produces no
    // error, so the message has to say what would otherwise happen.
    testSync("states the silent outcome it is preventing", () =>
      expect(message->String.includes("permanent verdict"))->toBe(true)
    )
  })
})
