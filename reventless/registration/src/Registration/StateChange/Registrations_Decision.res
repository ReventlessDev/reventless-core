@@reventless.decision

// Claim, challenge, settle, complete. The challenge rules are the shared
// contact-verification ones, with no host to supersede the address: registration
// is the arm of those rules that `hostContact = None` exists for.

module V = ContactVerification
module Guards = ContactVerification_Guards

let policy = V.emailPolicy

type policyState =
  /** Nothing recorded about the role: open if the app declares it
      self-service, closed otherwise. */
  | Unset
  | Closed
  | Open(option<Reventless.DateTime.t>)

type pending = {
  requestedAt: Reventless.DateTime.t,
  /** What a settled proof grants, as the registration asked for it. */
  roles: array<string>,
  challenge: option<Guards.challenge>,
  proofHash: option<string>,
}

type stage =
  | Unclaimed
  | Pending(pending)
  /** The proof settled and the account is being made. Still a claim: a second
      registration must not start while the first is turning into an account. */
  | Verified
  | Completed

type state = {
  admission: policyState,
  stage: stage,
  /** When a registered address was last told someone tried. */
  lastNoticeAt: option<Reventless.DateTime.t>,
}

let initialState = {admission: Unset, stage: Unclaimed, lastNoticeAt: None}

/** At most one "someone tried" notice per address in this many seconds. The
    caller is still answered as for a fresh address; only the mail is held back,
    so the door cannot be used to flood a registered person's inbox. */
let noticeCooldown = 3600

let evolve = (state, event) =>
  switch event {
  | RegistrationOpened({?until}) => {...state, admission: Open(until)}
  | RegistrationClosed(_) => {...state, admission: Closed}
  | RegistrationRequested({roles, requestedAt}) => {
      ...state,
      stage: Pending({requestedAt, roles, challenge: None, proofHash: None}),
    }
  | RegistrationExpired(_) => {...state, stage: Unclaimed}
  | RegistrationAttemptedOnTakenAddress({attemptedAt}) => {
      ...state,
      lastNoticeAt: Some(attemptedAt),
    }
  | RegistrationChallengeIssued({email, proofHash, issuedAt}) =>
    switch state.stage {
    | Pending(p) => {
        ...state,
        stage: Pending({
          ...p,
          challenge: Some({
            contact: ByEmail(Reventless.Email.unsafe(email->ContactAddressId.toString)),
            purpose: Registration,
            issuedAt,
            attempts: 0,
            settled: false,
          }),
          proofHash: Some(proofHash),
        }),
      }
    | _ => state
    }
  // A refusal is a fact, so the attempt budget survives a replay.
  | RegistrationProofRefused(_) =>
    switch state.stage {
    | Pending({challenge: Some(c)} as p) => {
        ...state,
        stage: Pending({...p, challenge: Some({...c, attempts: c.attempts + 1})}),
      }
    | _ => state
    }
  | RegistrationProofAccepted(_) => {...state, stage: Verified}
  | RegistrationCompleted(_) => {...state, stage: Completed}
  }

/** Whether the policy admits a registration for `role` that arrived at `at`.
    A role nobody has recorded anything about is open exactly when it is declared
    self-service; past an open window's end it refuses exactly as closed does,
    with no event to close it. */
let admits = (admission, ~table, ~role, ~at) =>
  switch admission {
  | Unset => table->Reventless.Admission.isSelfService(role)
  | Closed => false
  | Open(None) => true
  | Open(Some(until)) => Reventless.DateTime.isBefore(at, until)
  }

/** A pending registration nobody finished stops holding the address. Measured
    from its challenge when one went out, else from the request itself. */
let hasLapsed = (p: pending, ~now) =>
  switch p.challenge {
  | Some(c) => Guards.hasExpired(c, ~now, ~policy)
  | None => Guards.elapsedSeconds(~from=p.requestedAt, ~to_=now) >= policy.tokenTtl
  }

let refusalReason = (r: Guards.refusal) =>
  switch r {
  | AddressSuperseded => "AddressSuperseded"
  | ChallengeExpired => "ChallengeExpired"
  | AlreadySettled => "AlreadySettled"
  | AttemptsExhausted => "AttemptsExhausted"
  | ProofMismatch => "ProofMismatch"
  }

/** The decision over the app's table, which says which roles are self-service. */
module Make = (App: Reventless.Admission.Declaration) => {
  module Spec = Spec
  let moduleUrl = moduleUrl

  type state = state
  let initialState = initialState
  let evolve = evolve

  let decide = (state, command) =>
    switch command {
    // 🚨 Every arm answers `Ok`, and the order is the security decision: the
    // policy is consulted before the address, so a closed deployment sends nothing
    // — not even the notice to an address that is already registered.
    | Register({email, role, requestedAt}) =>
      if !admits(state.admission, ~table=App.table, ~role, ~at=requestedAt) {
        Ok([])
      } else {
        let roles = [(role :> string)]
        switch state.stage {
        // The caller is told nothing different; the address is told someone tried.
        | Completed =>
          switch state.lastNoticeAt {
          | Some(last) if Guards.elapsedSeconds(~from=last, ~to_=requestedAt) < noticeCooldown =>
            Ok([])
          | _ => Ok([RegistrationAttemptedOnTakenAddress({email, attemptedAt: requestedAt})])
          }
        | Verified => Ok([])
        | Pending(p) if !hasLapsed(p, ~now=requestedAt) => Ok([])
        | Pending(_) =>
          Ok([
            RegistrationExpired({email: email}),
            RegistrationRequested({email, roles, requestedAt}),
          ])
        | Unclaimed => Ok([RegistrationRequested({email, roles, requestedAt})])
        }
      }

    | IssueRegistrationChallenge({email, proofHash, issuedAt}) =>
      switch state.stage {
      | Pending(p) =>
        switch Guards.onIssueRequested(
          ~contact=ByEmail(Reventless.Email.unsafe(email->ContactAddressId.toString)),
          ~existing=p.challenge,
          ~now=issuedAt,
          ~policy,
        ) {
        | Issue => Ok([RegistrationChallengeIssued({email, proofHash, issuedAt})])
        // A redelivered request mints nothing, and because nothing is emitted,
        // sends nothing either.
        | AlreadyOpen => Ok([])
        }
      | _ => Ok([])
      }

    | SubmitRegistrationProof({email, proofHash, presentedAt}) =>
      switch state.stage {
      | Pending({challenge: Some(c), proofHash: Some(held), roles}) =>
        switch Guards.onProofPresented(
          c,
          ~hostContact=None,
          ~proofMatches=proofHash == held,
          ~now=presentedAt,
          ~policy,
        ) {
        | Settle => Ok([RegistrationProofAccepted({email, roles, proofHash})])
        | Refuse(reason) => Ok([RegistrationProofRefused({email, reason: refusalReason(reason)})])
        }
      // No challenge to answer: nothing to count it against, and nothing to say.
      | _ => Ok([])
      }

    | RecordRegistrationCompleted({email}) =>
      switch state.stage {
      | Verified => Ok([RegistrationCompleted({email: email})])
      | _ => Ok([])
      }
    }
}
