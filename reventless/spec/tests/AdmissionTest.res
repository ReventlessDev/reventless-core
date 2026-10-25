open JestGlobals

// How each role is admitted, as a plugin declares it and as it crosses a
// boundary as JSON. Every reading that cannot be sure refuses: a table read
// wrongly admits someone differently from how they were declared.

module Roles = {
  type t =
    | Admin
    | Shopper
    | Merchandiser
    | Fulfilment
}
let role = (r: Roles.t) => Role.make((r :> string))
let roles = [Roles.Admin, Shopper, Merchandiser, Fulfilment]->Array.map(role)

let table = Admission.declare([
  (Roles.Shopper, SelfService),
  (Merchandiser, Invitation({by: [Admin]})),
  (Admin, Provisioned),
])

let parse = text => text->JSON.parseOrThrow->Admission.fromJson(~roles)

describe("Admission", () => {
  testSync("a declared role reads its strategy", () =>
    expect((
      Admission.isSelfService(table, role(Shopper)),
      Admission.isSelfService(table, role(Merchandiser)),
    ))->toEqual((true, false))
  )

  testSync("a role the table does not name is provisioned", () =>
    expect(Admission.strategyOf(table, role(Fulfilment)))->toEqual(Admission.Provisioned)
  )

  testSync("the self-service roles, in declaration order", () =>
    expect(Admission.selfService(table))->toEqual([role(Shopper)])
  )

  testSync("the JSON form round-trips", () =>
    expect(table->Admission.toJson->Admission.fromJson(~roles))->toEqual(Ok(table))
  )

  testSync("an unknown strategy refuses rather than reading as provisioned", () =>
    expect(parse(`{"Shopper": "Open"}`))->toEqual(
      Error(`Admission: Shopper: "Open" is not a strategy`),
    )
  )

  testSync("an unknown role refuses", () =>
    expect(parse(`{"Guest": "SelfService"}`))->toEqual(
      Error("Admission: Guest is not a role of this plugin"),
    )
  )

  testSync("an inviter that is not a role refuses", () =>
    expect(parse(`{"Merchandiser": {"Invitation": {"by": ["Owner"]}}}`))->toEqual(
      Error("Admission: Merchandiser is by invitation from Owner, which is not a role"),
    )
  )

  testSync("an invitation nobody may send refuses", () =>
    expect(parse(`{"Merchandiser": {"Invitation": {"by": []}}}`))->toEqual(
      Error("Admission: Merchandiser is by invitation, but nobody may invite"),
    )
  )

  testSync("a case with a payload is not a role", () => {
    module Bad = {
      type t = Named(string)
    }
    let refused = switch Admission.declare([(Bad.Named("x"), Admission.SelfService)]) {
    | _ => false
    | exception _ => true
    }
    expect(refused)->toEqual(true)
  })

  testSync("the structure's form round-trips, invitation included", () => {
    let withInvitation = Admission.declare([
      (Roles.Shopper, SelfService),
      (Merchandiser, Invitation({by: [Admin]})),
    ])
    expect(withInvitation->Admission.toDefs->Admission.fromDefs)->toEqual(Ok(withInvitation))
  })

  testSync("a door's part is spelled once", () =>
    expect(
      [Admission.Start, Complete, Invite, OpenRoles]->Array.map(
        d => d->Admission.doorName->Admission.doorOfName,
      ),
    )->toEqual([Some(Admission.Start), Some(Complete), Some(Invite), Some(OpenRoles)])
  )

  testSync("a role declared twice refuses", () =>
    expect(
      Admission.declare([(Roles.Shopper, SelfService), (Shopper, Provisioned)])->Admission.validate(
        ~roles,
      ),
    )->toEqual(Error("Admission: Shopper is declared twice"))
  )
})
