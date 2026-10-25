@@reventless.gwt

open Registration_Examples

// Whether visitors may sign up for a role right now. A role declared
// self-service is open until an administrator closes it; a role not declared
// self-service has no policy to open, whatever an administrator says. Opening
// an open role or closing a closed one records nothing.

let until = "2026-10-31T00:00:00.000Z"

describe("RegistrationPolicy StateChangeSlice", () => {
  // Nothing recorded is open, so the first open records nothing.
  // scenario-id: 1df7c562-74b8-4405-b080-e0a2b673552b
  test("a self-service role is open before anything is recorded", () =>
    givenEvents([])->whenCmd(OpenRegistration({role: shopper}))->thenNoEvent
  )

  // scenario-id: af58e483-9fc1-41a1-8534-9d3df3b4d230
  test("an open window carries its end", () =>
    givenEvents([])
    ->whenCmd(OpenRegistration({role: shopper, until}))
    ->thenEvent(RegistrationOpened({role: shopper, until}))
  )

  // scenario-id: 794cc4eb-60f9-4bba-a7e2-6bd2675b9cbd
  test("opening an open role again records nothing", () =>
    givenEvents([RegistrationOpened({role: shopper})])
    ->whenCmd(OpenRegistration({role: shopper}))
    ->thenNoEvent
  )

  // Moving the end of a window is a change, so it is recorded.
  // scenario-id: 93cb2b9a-f220-4433-bfcc-34076b6c62a0
  test("giving an open role an end records it", () =>
    givenEvents([RegistrationOpened({role: shopper})])
    ->whenCmd(OpenRegistration({role: shopper, until}))
    ->thenEvent(RegistrationOpened({role: shopper, until}))
  )

  // scenario-id: b0700a95-4bcd-4018-8e5d-902dc784bc33
  test("closing an open role records it", () =>
    givenEvents([])
    ->whenCmd(CloseRegistration({role: shopper}))
    ->thenEvent(RegistrationClosed({role: shopper}))
  )

  // scenario-id: 6d20339a-e89b-445b-9df2-5b0464f2d1e7
  test("closing a closed role records nothing", () =>
    givenEvents([RegistrationClosed({role: shopper})])
    ->whenCmd(CloseRegistration({role: shopper}))
    ->thenNoEvent
  )

  // scenario-id: 3f0b6e2a-6c1d-4f7e-9a2b-5d8c1e4f7a90
  test("a closed role is opened again", () =>
    givenEvents([RegistrationClosed({role: shopper})])
    ->whenCmd(OpenRegistration({role: shopper}))
    ->thenEvent(RegistrationOpened({role: shopper}))
  )

  // The declaration is the hard cap: no command opens a role it does not
  // declare self-service.
  // scenario-id: 8d2c4b7e-1a3f-4e5d-b6c7-9f0a1b2c3d4e
  test("a role not declared self-service cannot be opened", () =>
    givenEvents([])
    ->whenCmd(OpenRegistration({role: merchandiser}))
    ->thenError(NotSelfService({role: merchandiser}))
  )

  // scenario-id: 87ea8d6f-fa39-43f9-8eb2-60fc1de38fa3
  test("only an administrator closes registration", () =>
    givenEvents([])
    ->asCaller(Caller.inRoles([]))
    ->whenCmd(CloseRegistration({role: shopper}))
    ->thenForbidden
  )
})
