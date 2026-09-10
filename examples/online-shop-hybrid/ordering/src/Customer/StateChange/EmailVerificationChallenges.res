// EmailVerificationChallenges StateChangeSlice.
//
// The challenge ledger: one open challenge per customer, holding the hash of the
// secret that was sent, when it went out, and how many times it has been
// answered wrongly.
//
// **Its own slice, and that is forced rather than preferred.** The challenge
// cannot live on `Customer`: an aggregate's state is snapshotted, so a secret
// held there is a secret in every snapshot and every backup of one. It also must
// not reach a read model, which is why nothing projects it — the *outcome*
// lands on `Customer` as `EmailVerified`, and only the outcome is projectable.
//
// **The secret never arrives here in the clear.** Commands carry a hash, and
// `decide` compares hashes. That keeps the decision pure and replayable — the
// same reason `issuedAt` and `presentedAt` are passed in rather than read from a
// clock — and it keeps the plaintext out of an append-only log. Producing the
// hash belongs to whoever opens the door; see the note in the plan about the
// framework offering nothing to produce it with.

@@reventless.spec

@schema
type consumedEvent =
  | EmailChallengeIssued({
      customerId: string,
      email: string,
      purpose: string,
      proofHash: string,
      issuedAt: string,
    })
  | EmailProofAccepted({customerId: string, email: string})
  | EmailProofRefused({customerId: string, email: string, reason: string})

@schema
type command =
  // Relayed by whatever decides an address needs proving, never a client door: a
  // caller who could issue challenges could send mail to any address they liked.
  | @noApi
  IssueEmailChallenge({
      customerId: string,
      email: string,
      purpose: string,
      proofHash: string,
      issuedAt: string,
    })
  // The inbound completion door. Carries the hash of what was presented, not the
  // secret itself.
  //
  // ⚠️ For a contact change the presenter is the account holder, so ordinary
  // authorization fits. Registration is the case that does not: the caller is
  // trying to *become* someone, and a component that brings a door cannot yet
  // declare that the door is open to the unauthenticated.
  | SubmitEmailProof({customerId: string, email: string, proofHash: string, presentedAt: string})

@schema
type error =
  // Refusals are recorded as facts rather than returned, so an attempt against a
  // spent or expired challenge is counted rather than lost. This one is for a
  // proof presented when the ledger holds nothing at all — there is no challenge
  // to count it against.
  | NoChallengeOutstanding

@schema
type event =
  | EmailChallengeIssued({
      customerId: string,
      email: string,
      purpose: string,
      proofHash: string,
      issuedAt: string,
    })
  | EmailProofAccepted({customerId: string, email: string})
  | EmailProofRefused({customerId: string, email: string, reason: string})
