// SignUp InboundTranslationSlice.
//
// The anonymous door a registration starts at. It reads the address, stamps the
// moment the request arrived — the time the policy's open window is measured
// against, so a caller cannot choose it — and relays a `Register` to the
// ledger. What happens next is the ledger's, and the caller learns none of it:
// a closed policy, a taken address and a fresh one all answer alike.
//
// Anonymous because the caller is trying to become someone. The local platform
// honors that; a deployed one refuses the rule until it has a door of its own,
// which is why this plugin is hosted by the local platform only.

@@reventless.spec
@@reventless.authorize(AllowAnonymous)

@schema
type externalInput = {email: string}

@schema
type command =
  Register({email: ContactAddressId.t, scopeId: string, requestedAt: Reventless.DateTime.t})

let targetName = "Registrations"
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
