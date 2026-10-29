// SignUp InboundTranslationSlice.
//
// The anonymous door a registration starts at. It reads the address and the role
// asked for, stamps the moment the request arrived — the time the policy's open
// window is measured against, so a caller cannot choose it — and relays a
// `Register` to the ledger. What happens next is the ledger's, and the caller
// learns none of it: a closed role, a role no visitor may have, a taken address
// and a fresh one all answer alike.
//
// Anonymous because the caller is trying to become someone. The local platform
// honors that; a deployed one refuses the rule until it has a door of its own,
// which is why a plugin listing these slices is hosted by the local platform
// only.

@@reventless.spec
@@reventless.authorize(AllowAnonymous)

/** `role` may be left out where exactly one role is open to visitors; with
    several, a sign-up has to say which. */
@schema
type externalInput = {email: string, role?: string}

@schema
type command =
  | Register({
      email: ContactAddressId.t,
      @pii({subject: "email"}) address: Reventless.Email.t,
      role: Reventless.Role.name,
      requestedAt: Reventless.DateTime.t,
    })

let targetName = "Registrations"
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []

/** This door starts a registration; the platform tells the shell so. */
let admissionDoor = Reventless.Admission.Start
