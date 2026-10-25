// RegistrationPolicy StateChangeSlice.
//
// Whether visitors may sign themselves up for a role right now, as domain state
// an administrator changes with a command rather than a deploy. Kept per role:
// only a role `Admission.res` declares self-service has a policy at all, and
// such a role is open until an administrator closes it — the declaration is the
// deployer's opt-in, so needing a second command to make it do anything would be
// a trap.
//
// An open window may carry an end, checked against the time the registration
// arrived, so a test window someone forgets to close closes itself.

@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))

// The role is this slice's partition, tagged by its type: a role is an identity
// the framework declares, not an id the plugin names.
@schema
type consumedEvent =
  | RegistrationOpened({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
      until?: Reventless.DateTime.t,
    })
  | RegistrationClosed({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
    })

@schema
type command =
  | OpenRegistration({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
      until?: Reventless.DateTime.t,
    })
  | CloseRegistration({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
    })

// Told to an administrator, never to a visitor: this slice's commands are an
// administrator's.
@schema
type error = NotSelfService({role: Reventless.Role.name})

@schema
type event =
  | RegistrationOpened({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
      until?: Reventless.DateTime.t,
    })
  | RegistrationClosed({
      role: @s.matches(Reventless.DcbTag.mark(Reventless.Role.nameSchema)) Reventless.Role.name,
    })
