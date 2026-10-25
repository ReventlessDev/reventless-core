// RegistrationWindows StateViewSliceStream.
//
// Which self-service roles an administrator has closed or opened, for a visitor
// deciding whether to sign up. Open to callers who are not signed in, and it
// tells them only what the door's own answers already tell: that registration
// for a role is or is not open here. Nothing about any address.
//
// A role with no row is open, since nothing recorded about a self-service role
// is open; the shell learns which roles are self-service from the platform's
// configuration and reads this view for the exceptions.

@@reventless.spec
@@reventless.authorize(AllowAnonymous)

@schema
type state = {
  @id role: string,
  isOpen: bool,
  // The end of an open window, where one was given. Past it the role reads as
  // closed, with no event to say so.
  until: option<Reventless.DateTime.t>,
}

@schema
type consumedEvent =
  | RegistrationOpened({role: string, until?: Reventless.DateTime.t})
  | RegistrationClosed({role: string})
