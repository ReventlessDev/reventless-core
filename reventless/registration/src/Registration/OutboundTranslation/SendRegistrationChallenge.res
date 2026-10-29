// SendRegistrationChallenge OutboundTranslationSlice.
//
// Writes to the address a registration names. Work is keyed by the ledger's id
// for the address, its fingerprint, never by the address.
//
// Writes to the address a registration names. A fresh registration gets a
// secret to prove control of the address, and the ledger records its hash; an
// invitation gets one too, worded as an invitation and holding for a week; a
// reissued code is a fresh secret worded as its claim was. An address that is
// already registered gets a notice instead, saying someone tried. The caller who started either sees the same answer — the difference
// arrives at the address, where only its owner reads it.
//
// The plaintext goes to the address and never into the log. On the local
// platform the log transport prints the message, which is how a developer reads
// the secret and finishes a registration with no mailbox at all.

@@reventless.spec

@schema
type consumedEvent =
  | RegistrationRequested({
      email: string,
      address: Reventless.Email.t,
      requestedAt: Reventless.DateTime.t,
    })
  | RegistrationAttemptedOnTakenAddress({
      email: string,
      address: Reventless.Email.t,
      attemptedAt: Reventless.DateTime.t,
    })
  | RegistrationInvited({
      email: string,
      address: Reventless.Email.t,
      roles: array<string>,
      invitedBy: string,
      invitedAt: Reventless.DateTime.t,
    })
  | RegistrationChallengeReissued({
      email: string,
      address: Reventless.Email.t,
      reissuedAt: Reventless.DateTime.t,
      invitedBy?: string,
    })

/** `invited` words the secret as an invitation; it is left out for a sign-up
    and for the notice. `roles` names what the invitation grants, where the
    event said: a reissued code does not. */
// `email` is the ledger's id for the address, `address` the address the mail goes to.
@schema
type outboundItem = {
  email: string,
  address: Reventless.Email.t,
  alreadyRegistered: bool,
  invited?: bool,
  roles?: array<string>,
}

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
