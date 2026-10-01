open JestGlobals

// `Caller.owner` takes an id as a scenario holds it, typed or not, so a test
// never converts one by hand.

module CustomerId = Reventless.Id.Make({
  let key = "customerId"
})

describe("Caller.owner", () => {
  testSync("takes a typed id as the user id it stands for", () =>
    expect(Behavior_GWT.Caller.owner(CustomerId.makeFromString("c1")))->toEqual(
      Reventless.Message.CallerClaim.Owned({userId: "c1"}),
    )
  )

  testSync("takes a plain string too", () =>
    expect(Behavior_GWT.Caller.owner("c1"))->toEqual(
      Reventless.Message.CallerClaim.Owned({userId: "c1"}),
    )
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
