// SignUp InboundTranslationSlice.
//
// The anonymous door a registration starts at. It reads the address and the role
// asked for, stamps the moment the request arrived — the time the policy's open
// window is measured against, so a caller cannot choose it — and relays a
// `Register` to the ledger. What happens next is the ledger's, and the caller
// learns none of it: a closed role, a role no visitor may have, a taken address
// and a fresh one all answer alike.
//
// First it asks the person check whether a person sent the request; a missing,
// failed or unanswerable check relays nothing and says so, which names no address.
//
// Anonymous because the caller is trying to become someone. A deployed platform
// hosts it on a door for visitors, with its guards.

@@reventless.spec
@@reventless.authorize(AllowAnonymous)

/** `role` may be left out where exactly one role is open to visitors; with
    several, a sign-up has to say which. `language` is the one the visitor reads the
    shell in, which their mails are written in where the deployment offers it.
    `personCheck` is the token of the widget the deployment names, if it names one. */
@schema
type externalInput = {
  @sensitive email: string,
  role?: string,
  language?: string,
  @sensitive personCheck?: string,
}

@schema
type command =
  | Register({
      emailId: ContactAddressId.t,
      @pii({subject: "emailId"}) email: Reventless.Email.t,
      role: Reventless.Role.name,
      requestedAt: Reventless.DateTime.t,
      language?: string,
      initially?: @s.matches(Reventless.Admission.initiallySchema) Reventless.Admission.initially,
    })

let targetName = "Registrations"
let capabilityNeeds = [Reventless.CapabilityNeed.PersonCheck]

/** This door starts a registration; the platform tells the shell so. */
let admissionDoor = Reventless.Admission.Start
