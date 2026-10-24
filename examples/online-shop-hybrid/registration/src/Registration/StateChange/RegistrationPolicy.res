// RegistrationPolicy StateChangeSlice.
//
// Who may start a registration, as domain state an administrator changes with a
// command rather than a deploy setting. Nothing recorded means closed: an
// event-sourced setting has no value until someone sets one, and the safe answer
// before then is that nobody may register.
//
// **Keyed by scope from the first event.** One scope is used today, `default`,
// and a later layer that wants a policy per organization supplies other keys
// without moving a single event.
//
// Of the three admission questions — who may start, what must be true of the
// address, what a settled proof grants — only the first varies here, between
// closed and open. An open window may carry an end, checked against the time the
// registration arrived, so a test window someone forgets to close closes itself.

@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))

@schema
type consumedEvent =
  | RegistrationOpened({scopeId: string, until?: Reventless.DateTime.t})
  | RegistrationClosed({scopeId: string})

@schema
type command =
  | OpenRegistration({scopeId: string, until?: Reventless.DateTime.t})
  | CloseRegistration({scopeId: string})

@schema
type error = unit

@schema
type event =
  | RegistrationOpened({scopeId: string, until?: Reventless.DateTime.t})
  | RegistrationClosed({scopeId: string})
