// CreateRegisteredPrincipal OutboundTranslationSlice.
//
// Turns an accepted proof into an account. The password is the one the person
// typed beside the proof: the door held it in the stash under the proof's hash,
// because it could not know whether the proof would be accepted, and this slice
// takes it now that the ledger has said yes.
//
// The account is made in the deployment's identity provider — on the local
// platform, the accounts file its login reads — and the ledger is told the
// registration completed.

@@reventless.spec

@schema
type consumedEvent = RegistrationProofAccepted({email: string, proofHash: string})

@schema
type outboundItem = {email: string, proofHash: string}

@schema
type inboundCommand = RecordRegistrationCompleted({email: ContactAddressId.t})

// For a provider that is down. The password is put back before each retry, so a
// retry finds it; once the budget is spent, it expires.
let maxRetries = 3
let targetName = Some("Registrations")
let sourceNames: array<string> = []
let capabilityNeeds = [Reventless.CapabilityNeed.Stash, Reventless.CapabilityNeed.IdentityProvider]
