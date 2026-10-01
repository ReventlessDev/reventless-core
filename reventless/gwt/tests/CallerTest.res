open JestGlobals

// `Caller.owner` takes an id as a scenario holds it, typed or not, so a test
// never converts one by hand; roles arrive as the plugin's own `Roles.t`.

module CustomerId = Reventless.Id.Make({
  let key = "customerId"
})

module Roles = {
  type t = Merchandiser
}

describe("Caller.owner", () => {
  testSync("takes a typed id as the user id it stands for", () =>
    expect(Behavior_GWT.Caller.owner(CustomerId.makeFromString("c1")).claim)->toEqual(
      Reventless.Message.CallerClaim.Owned({userId: "c1"}),
    )
  )

  testSync("takes a plain string too", () =>
    expect(Behavior_GWT.Caller.owner("c1").claim)->toEqual(
      Reventless.Message.CallerClaim.Owned({userId: "c1"}),
    )
  )

  testSync("holds no role unless given some", () =>
    expect(Behavior_GWT.Caller.owner("c1").roles)->toEqual([])
  )

  testSync("holds the roles it is given, by name", () =>
    expect(Behavior_GWT.Caller.owner("c1", ~roles=[Roles.Merchandiser]).roles)->toEqual([
      "Merchandiser",
    ])
  )

  // Anything that is not a string at runtime is not an id, and comparing it
  // with a recorded owner would only ever refuse — a silent wrong answer.
  testSync("refuses a value that is not an id", () =>
    expect(
      switch Behavior_GWT.Caller.owner(42) {
      | _ => false
      | exception _ => true
      },
    )->toBe(true)
  )
})

describe("Caller.inRoles", () => {
  testSync("is signed in, holds the roles, and owns nothing in particular", () => {
    let caller = Behavior_GWT.Caller.inRoles([Roles.Merchandiser])
    expect((caller.signedIn, caller.roles))->toEqual((true, ["Merchandiser"]))
  })

  testSync("refuses a role that is not a payload-less case", () =>
    expect(
      switch Behavior_GWT.Caller.inRoles([42]) {
      | _ => false
      | exception _ => true
      },
    )->toBe(true)
  )
})
