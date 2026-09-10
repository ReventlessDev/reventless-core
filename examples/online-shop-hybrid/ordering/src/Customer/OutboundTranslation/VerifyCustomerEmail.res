// VerifyCustomerEmail: mints a secret for an address that has not been proven,
// sends it, and opens a challenge in the ledger against its hash.
//
// The plaintext goes to the address and never into the log; what is recorded is
// the hash, so the event stream holds nothing that would answer a challenge.

@@reventless.spec

// Only the triggers. A registered address is unproven and an updated one stops
// being proven, so both owe a challenge; `EmailVerified` is deliberately absent,
// because a settled address owes nothing and the slice must not re-open it.
@schema
type consumedEvent =
  | Registered({email: string, address: string})
  | EmailUpdated({email: string})

@schema
type outboundItem = {customerId: string, email: string}

// Reported to the challenge ledger rather than to `Customer` — the aggregate
// learns nothing until a proof settles. Mirrors that slice's command exactly.
@schema
type inboundCommand =
  | IssueEmailChallenge({
      customerId: string,
      email: string,
      purpose: string,
      proofHash: string,
      issuedAt: string,
    })

// Retries are for a mail transport that is down. A refused address is not
// retried, and exhausting delivery retries is not a verdict on the verification
// — the challenge simply never opens, and the address stays unproven.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("EmailVerificationChallenges")

let sourceNames = ["Customer"]

// Both are reached in one translation: the secret is drawn, then sent. Declared
// so a deployment provisioning neither fails the deploy rather than silently
// never proving an address.
let capabilityNeeds = [Reventless.CapabilityNeed.Messaging]
