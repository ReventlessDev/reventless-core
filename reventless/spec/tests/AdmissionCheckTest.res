open JestGlobals

// Whether a deployment can honor what its plugins declare about admission. Each
// declaration nothing honors is named with its role and the reason, so the
// refusal says what to change.

module Roles = {
  type t =
    | Admin
    | Shopper
    | Merchandiser
}

let table = (pairs: array<(Roles.t, Admission.strategy<Roles.t>)>) =>
  pairs->Admission.declare->Admission.toDefs

let empty: Plugin.pluginStructure = {
  readModels: [],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
}

let doors = (parts: array<Admission.door>): array<Admission.doorDef> =>
  parts->Array.map(part => {
    Admission.component: Admission.doorName(part)->String.toUpperCase,
    part: Admission.doorName(part),
  })

let shop = (~admission, ~doors as ds=doors([Start, Complete])): Plugin.pluginStructure => {
  ...empty,
  admission,
  admissionDoors: ds,
}

let all = [CapabilityNeed.Messaging, CapabilityNeed.IdentityProvider]

let problems = (
  structures,
  ~provisioned=all,
  ~elevatedGroups=["Fulfilment"],
  ~adminGroup="Admin",
  ~anonymousDoors=true,
) =>
  AdmissionCheck.problems(
    ~structures,
    ~provisioned,
    ~elevatedGroups,
    ~adminGroup,
    ~anonymousDoors,
  )->Array.map(AdmissionCheck.describe)

describe("AdmissionCheck", () => {
  testSync("a plugin declaring nothing raises nothing", () =>
    expect(problems([("Catalog", empty)]))->toEqual([])
  )

  testSync("self-service and provisioned with both doors and both capabilities is honored", () =>
    expect(
      problems([
        ("Shop", shop(~admission=table([(Roles.Shopper, SelfService), (Admin, Provisioned)]))),
      ]),
    )->toEqual([])
  )

  testSync("a self-service role whose group is elevated is refused", () =>
    expect(problems([("Shop", shop(~admission=table([(Roles.Admin, SelfService)])))]))->toEqual([
      "Shop: Admin is self-service, but its group Admin is elevated: anyone could sign up as an operator",
    ])
  )

  testSync("a self-service role on a platform without anonymous doors is refused", () =>
    expect(
      problems(
        [("Shop", shop(~admission=table([(Roles.Shopper, SelfService)])))],
        ~anonymousDoors=false,
      ),
    )->toEqual([
      "Shop: Shopper is self-service, but this platform has no door for callers who are not signed in",
    ])
  )

  testSync("a self-service role without a door that starts and completes is refused", () =>
    expect(
      problems([
        ("Shop", shop(~admission=table([(Roles.Shopper, SelfService)]), ~doors=doors([Start]))),
      ]),
    )->toEqual([
      "Shop: Shopper is self-service, but no door in Shop starts and completes a registration",
    ])
  )

  testSync("a self-service role without the capabilities names the missing ones", () =>
    expect(
      problems(
        [("Shop", shop(~admission=table([(Roles.Shopper, SelfService)])))],
        ~provisioned=[CapabilityNeed.Stash],
      ),
    )->toEqual([
      "Shop: Shopper is self-service, but this platform provisions no Messaging and no IdentityProvider",
    ])
  )

  testSync("a role by invitation with nothing that invites is refused", () =>
    expect(
      problems([
        ("Shop", shop(~admission=table([(Roles.Merchandiser, Invitation({by: [Admin]}))]))),
      ]),
    )->toEqual([
      "Shop: Merchandiser is by invitation, but nothing in this deployment provides invitations",
    ])
  )

  testSync("an invite door in another plugin honors a role by invitation", () =>
    expect(
      problems([
        ("Shop", shop(~admission=table([(Roles.Merchandiser, Invitation({by: [Admin]}))]))),
        ("Accounts", {...empty, admissionDoors: doors([Invite])}),
      ]),
    )->toEqual([])
  )

  testSync("a table that cannot be read is refused rather than read past", () =>
    expect(
      problems([
        ("Shop", shop(~admission=[{Admission.role: "Shopper", strategy: "Open"}])),
      ])->Array.length,
    )->toEqual(1)
  )

  testSync("check throws with every problem", () => {
    let refused = switch AdmissionCheck.check(
      ~structures=[("Shop", shop(~admission=table([(Roles.Admin, SelfService)])))],
      ~provisioned=all,
      ~elevatedGroups=[],
      ~adminGroup="Admin",
      ~anonymousDoors=true,
    ) {
    | () => false
    | exception _ => true
    }
    expect(refused)->toEqual(true)
  })
})
