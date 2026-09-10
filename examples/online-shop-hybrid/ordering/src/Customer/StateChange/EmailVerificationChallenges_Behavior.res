@@reventless.behavior

// Issue, expire, count and settle. The rules are the graft's; this slice holds
// the state they read and names the facts they allow.
module V = ContactVerification
module Guards = ContactVerification_Guards

// The rules' view of a challenge, plus the hash a presented proof is compared
// against — which the rules deliberately never see. They are handed the result
// of the comparison, not the material for it.
type open_ = {challenge: Guards.challenge, proofHash: string}

type state = {current: option<open_>}

let initialState = {current: None}

// One purpose is exercised here, and the field is a string for the reason a
// persisted structure holds strings anywhere else: an older reader must still
// decode an event a newer build wrote.
let purposeOf = (raw: string): V.purpose =>
  switch raw {
  | "Registration" => Registration
  | "Invitation" => Invitation
  | "Recovery" => Recovery
  | "ContactChange" => ContactChange
  | other => Custom(other)
  }

let evolve = (state, event) =>
  switch event {
  | EmailChallengeIssued({email, purpose, proofHash, issuedAt}) => {
      current: Some({
        challenge: {
          contact: ByEmail(email),
          purpose: purposeOf(purpose),
          issuedAt,
          attempts: 0,
          settled: false,
        },
        proofHash,
      }),
    }
  | EmailProofAccepted(_) =>
    switch state.current {
    | Some(o) => {current: Some({...o, challenge: {...o.challenge, settled: true}})}
    | None => state
    }
  // A refusal is a fact, so the count survives a replay — an attempt budget that
  // only existed in memory would reset on every rebuild.
  | EmailProofRefused(_) =>
    switch state.current {
    | Some(o) => {
        current: Some({...o, challenge: {...o.challenge, attempts: o.challenge.attempts + 1}}),
      }
    | None => state
    }
  }

let policy = V.emailPolicy

let refusalReason = (r: Guards.refusal) =>
  switch r {
  | AddressSuperseded => "AddressSuperseded"
  | ChallengeExpired => "ChallengeExpired"
  | AlreadySettled => "AlreadySettled"
  | AttemptsExhausted => "AttemptsExhausted"
  | ProofMismatch => "ProofMismatch"
  }

let decide = (state, command) =>
  switch command {
  | IssueEmailChallenge({customerId, email, purpose, proofHash, issuedAt}) =>
    switch Guards.onIssueRequested(
      ~contact=ByEmail(email),
      ~existing=state.current->Option.map(o => o.challenge),
      ~now=issuedAt,
      ~policy,
    ) {
    | Issue => Ok([EmailChallengeIssued({customerId, email, purpose, proofHash, issuedAt})])
    // A redelivered request mints nothing and, because nothing is emitted, sends
    // nothing either — the send hangs off the event.
    | AlreadyOpen => Ok([])
    }

  | SubmitEmailProof({customerId, email, proofHash, presentedAt}) =>
    switch state.current {
    | None => Error(NoChallengeOutstanding)
    | Some(o) =>
      switch Guards.onProofPresented(
        o.challenge,
        // The ledger does not track the customer's current address, so it has no
        // supersession of its own to check. `Customer.decide` refuses a verdict
        // for an address it has moved off, and that check is inside the boundary
        // that owns the address — which is why it is the one that must exist.
        ~hostContact=None,
        ~proofMatches=proofHash == o.proofHash,
        ~now=presentedAt,
        ~policy,
      ) {
      | Settle => Ok([EmailProofAccepted({customerId, email})])
      | Refuse(reason) =>
        Ok([EmailProofRefused({customerId, email, reason: refusalReason(reason)})])
      }
    }
  }
