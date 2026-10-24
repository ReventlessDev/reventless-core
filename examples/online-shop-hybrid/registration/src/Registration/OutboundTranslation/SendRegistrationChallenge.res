// SendRegistrationChallenge OutboundTranslationSlice.
//
// Writes to the address a registration names. A fresh registration gets a
// secret to prove control of the address, and the ledger records its hash; an
// address that is already registered gets a notice instead, saying someone
// tried. The caller who started either sees the same answer — the difference
// arrives at the address, where only its owner reads it.
//
// The plaintext goes to the address and never into the log. On the local
// platform the log transport prints the message, which is how a developer reads
// the secret and finishes a registration with no mailbox at all.

@@reventless.spec

@schema
type consumedEvent =
  | RegistrationRequested({email: string, requestedAt: Reventless.DateTime.t})
  | RegistrationAttemptedOnTakenAddress({email: string, attemptedAt: Reventless.DateTime.t})

@schema
type outboundItem = {email: string, alreadyRegistered: bool}

@schema
type inboundCommand =
  | IssueRegistrationChallenge({
      email: ContactAddressId.t,
      proofHash: string,
      issuedAt: Reventless.DateTime.t,
    })

// For a mail transport that is down. Exhausting them opens no challenge, which
// leaves the registration to lapse and the address free to try again.
let maxRetries = 3
let targetName = Some("Registrations")
let sourceNames: array<string> = []
let capabilityNeeds = [Reventless.CapabilityNeed.Messaging]
