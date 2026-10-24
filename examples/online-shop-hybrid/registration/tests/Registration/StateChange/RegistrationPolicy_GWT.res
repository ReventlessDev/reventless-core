@@reventless.gwt

open Registration_Examples

// Who may start a registration. Nothing recorded is closed; an administrator
// opens and closes a scope, and doing either twice records nothing.

let scope = defaultScope
let until = "2026-10-31T00:00:00.000Z"

describe("RegistrationPolicy StateChangeSlice", () => {
  // scenario-id: 1df7c562-74b8-4405-b080-e0a2b673552b
  test("opening a closed scope records it", () =>
    givenEvents([])
    ->whenCmd(OpenRegistration({scopeId: scope}))
    ->thenEvent(RegistrationOpened({scopeId: scope}))
  )

  // scenario-id: af58e483-9fc1-41a1-8534-9d3df3b4d230
  test("an open window carries its end", () =>
    givenEvents([])
    ->whenCmd(OpenRegistration({scopeId: scope, until}))
    ->thenEvent(RegistrationOpened({scopeId: scope, until}))
  )

  // scenario-id: 794cc4eb-60f9-4bba-a7e2-6bd2675b9cbd
  test("opening an open scope again records nothing", () =>
    givenEvents([RegistrationOpened({scopeId: scope})])
    ->whenCmd(OpenRegistration({scopeId: scope}))
    ->thenNoEvent
  )

  // Moving the end of a window is a change, so it is recorded.
  // scenario-id: 93cb2b9a-f220-4433-bfcc-34076b6c62a0
  test("giving an open scope an end records it", () =>
    givenEvents([RegistrationOpened({scopeId: scope})])
    ->whenCmd(OpenRegistration({scopeId: scope, until}))
    ->thenEvent(RegistrationOpened({scopeId: scope, until}))
  )

  // scenario-id: b0700a95-4bcd-4018-8e5d-902dc784bc33
  test("closing an open scope records it", () =>
    givenEvents([RegistrationOpened({scopeId: scope})])
    ->whenCmd(CloseRegistration({scopeId: scope}))
    ->thenEvent(RegistrationClosed({scopeId: scope}))
  )

  // scenario-id: 6d20339a-e89b-445b-9df2-5b0464f2d1e7
  test("closing a scope that was never opened records nothing", () =>
    givenEvents([])->whenCmd(CloseRegistration({scopeId: scope}))->thenNoEvent
  )

  // scenario-id: 87ea8d6f-fa39-43f9-8eb2-60fc1de38fa3
  test("only an administrator opens registration", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([]))
    ->whenCmd(OpenRegistration({scopeId: scope}))
    ->thenForbidden
  )
})
