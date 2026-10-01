// `asCaller` with roles: a command's `@authorize` rule is checked against the
// caller's roles before `decide`, and before the ownership rule, as production
// checks them. A scenario without `asCaller` is checked against neither.

@@reventless.gwt

module ShelveSlice = {
  let name = "Shelve"

  // Inside the spec, so the zero-argument form still finds the spec and its
  // behaviour first; the rule's `Roles` resolves by ordinary scoping either way.
  module Roles = {
    type t =
      | Admin
      | Merchandiser
  }

  @schema
  type consumedEvent = ShelfOpened({shelfId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type command =
    | @authorize(AllowRoles([Admin, Merchandiser]))
    Shelve({
        shelfId: @s.matches(Reventless.DcbTag.string) string,
      })
    | Browse({shelfId: @s.matches(Reventless.DcbTag.string) string})
    | @authorize(AllowAnonymous) Peek({shelfId: @s.matches(Reventless.DcbTag.string) string})
    | @authorize(DenyAll) Purge({shelfId: @s.matches(Reventless.DcbTag.string) string})

  @schema
  type error = unit

  @schema
  type event = Done({shelfId: @s.matches(Reventless.DcbTag.string) string})
}

module ShelveSliceBehavior = {
  module Spec = ShelveSlice
  open ShelveSlice

  type state = unit
  let initialState = ()
  let evolve = (_state, _event: consumedEvent) => ()
  let decide = (_state, command: command): result<array<event>, error> =>
    switch command {
    | Shelve({shelfId}) | Browse({shelfId}) | Peek({shelfId}) | Purge({shelfId}) =>
      Ok([Done({shelfId: shelfId})])
    }
}

let s1 = "s1"

describe("a command's rule, checked against the caller's roles", () => {
  test("accepted for each role the rule names: Admin", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(Shelve({shelfId: s1}))
    ->thenEvent(Done({shelfId: s1}))
  )

  test("accepted for each role the rule names: Merchandiser", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(Shelve({shelfId: s1}))
    ->thenEvent(Done({shelfId: s1}))
  )

  test("refused for a signed-in caller holding none of them", () =>
    givenEvents([])->asCaller(Caller.owner("c1"))->whenCmd(Shelve({shelfId: s1}))->thenRefused
  )

  test("refused for an anonymous caller", () =>
    givenEvents([])->asCaller(Caller.anonymous)->whenCmd(Shelve({shelfId: s1}))->thenRefused
  )

  // Elevation lifts ownership rules, not rules about who may issue a command.
  test("refused for an operator, who holds no role", () =>
    givenEvents([])->asCaller(Caller.operator)->whenCmd(Shelve({shelfId: s1}))->thenRefused
  )

  test("DenyAll refuses every caller, Admin included", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(Purge({shelfId: s1}))
    ->thenRefused
  )

  test("AllowAnonymous accepts an anonymous caller", () =>
    givenEvents([])
    ->asCaller(Caller.anonymous)
    ->whenCmd(Peek({shelfId: s1}))
    ->thenEvent(Done({shelfId: s1}))
  )

  test("the default rule refuses an anonymous caller", () =>
    givenEvents([])->asCaller(Caller.anonymous)->whenCmd(Browse({shelfId: s1}))->thenRefused
  )

  test("a scenario without asCaller is checked against no rule", () =>
    givenEvents([])->whenCmd(Purge({shelfId: s1}))->thenEvent(Done({shelfId: s1}))
  )
})

// The same command on a slice whose history records an owner, through the same
// functor the attribute includes, to show the two checks in production's order.
module ClaimSlice = {
  let name = "Claim"

  module Roles = {
    type t = Merchandiser
  }

  @schema
  type consumedEvent =
    | ShelfClaimed({
        shelfId: @s.matches(Reventless.DcbTag.string) string,
        owner: @s.matches(Reventless.Owner.string) string,
      })

  @schema
  type command =
    | @authorize(AllowRoles([Merchandiser]))
    Shelve({
        shelfId: @s.matches(Reventless.DcbTag.string) string,
      })

  @schema
  type error = unit

  @schema
  type event = Done({shelfId: @s.matches(Reventless.DcbTag.string) string})
}

module Claim = Behavior_GWT.Make(
  ClaimSlice,
  {
    type state = unit
    let initialState = ()
    let evolve = (_state, _event: ClaimSlice.consumedEvent) => ()
    let decide = (_state, command: ClaimSlice.command): result<
      array<ClaimSlice.event>,
      ClaimSlice.error,
    > =>
      switch command {
      | Shelve({shelfId}) => Ok([Done({shelfId: shelfId})])
      }
  },
)

let claimedByC1 = [ClaimSlice.ShelfClaimed({shelfId: s1, owner: "c1"})]

describe("the rule, then ownership", () => {
  Claim.test("an owner holding the role acts on what they own", () =>
    Claim.givenEvents(claimedByC1)
    ->Claim.asCaller(Claim.Caller.owner("c1", ~roles=[Merchandiser]))
    ->Claim.whenCmd(Shelve({shelfId: s1}))
    ->Claim.thenEvent(Done({shelfId: s1}))
  )

  Claim.test("passing the rule does not let a caller act on someone else's thing", () =>
    Claim.givenEvents(claimedByC1)
    ->Claim.asCaller(Claim.Caller.owner("c2", ~roles=[Merchandiser]))
    ->Claim.whenCmd(Shelve({shelfId: s1}))
    ->Claim.thenRefused
  )

  Claim.test("owning a thing does not pass a rule the owner fails", () =>
    Claim.givenEvents(claimedByC1)
    ->Claim.asCaller(Claim.Caller.owner("c1"))
    ->Claim.whenCmd(Shelve({shelfId: s1}))
    ->Claim.thenRefused
  )
})
