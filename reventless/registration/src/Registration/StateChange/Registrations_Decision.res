@@reventless.decision

// Claim, challenge, settle, complete. The challenge rules are the shared
// contact-verification ones, with no host to supersede the address: registration
// is the arm of those rules that `hostContact = None` exists for. A claim starts
// one of two ways — a visitor signing up, or a signed-in inviter — and ends the
// same way, at the one completion door.

module V = ContactVerification
module Guards = ContactVerification_Guards

type policyState =
  /** Nothing recorded about the role: open if the app declares it
      self-service, closed otherwise. */
  | Unset
  | Closed
  | Open(option<Reventless.DateTime.t>)

type pending = {
  /** The address the claim was made for: where its code goes, and what an
      accepted proof makes an account for. */
  email: Reventless.Pii.t<Reventless.Email.t>,
  /** When the claim was made, or its code last reissued: what a claim with no
      challenge out lapses from. */
  requestedAt: Reventless.DateTime.t,
  /** What a settled proof grants, as the registration asked for it. */
  roles: array<string>,
  /** Who invited, for a claim an inviter made. */
  invitedBy?: string,
  /** The language the claim was made in: what its codes are written in for a person with no
      account to say. */
  language?: string,
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

/** The contact a challenge is held against. The guards only compare it, so the
    ledger's id for the address serves, and no address is needed to decide. */
let contactOf = (emailId: ContactAddressId.t): ContactVerification.contact => ByEmail(
  Reventless.Email.unsafe(emailId->ContactAddressId.toString),
)

let purposeOf = (p: pending) => RegistrationChallenge.purposeOf(~invitedBy=p.invitedBy)

/** The challenge rules a pending registration is held to: an invitation's code
    holds longer than a sign-up's. */
let policyOf = (p: pending) => RegistrationChallenge.policyFor(purposeOf(p))

let evolve = (state, event) =>
  switch event {
  | RegistrationOpened({?until}) => {...state, admission: Open(until)}
  | RegistrationClosed(_) => {...state, admission: Closed}
  | RegistrationRequested({email, roles, requestedAt, ?language}) => {
      ...state,
      stage: Pending({email, requestedAt, roles, ?language, challenge: None, proofHash: None}),
    }
  | RegistrationInvited({email, roles, invitedBy, invitedAt, ?language}) => {
      ...state,
      stage: Pending({
        email,
        requestedAt: invitedAt,
        roles,
        invitedBy,
        ?language,
        challenge: None,
        proofHash: None,
      }),
    }
  | RegistrationExpired(_) | RegistrationWithdrawn(_) => {...state, stage: Unclaimed}
  | RegistrationAttemptedOnTakenAddress({attemptedAt}) => {
      ...state,
      lastNoticeAt: Some(attemptedAt),
    }
  | RegistrationChallengeIssued({emailId, proofHash, issuedAt}) =>
    switch state.stage {
    | Pending(p) => {
        ...state,
        stage: Pending({
          ...p,
          challenge: Some({
            contact: contactOf(emailId),
            purpose: purposeOf(p),
            issuedAt,
            attempts: 0,
            settled: false,
          }),
          proofHash: Some(proofHash),
        }),
      }
    | _ => state
    }
  // The code is void and its attempts with it; the claim waits for the next one
  // from now.
  | RegistrationChallengeReissued({reissuedAt}) =>
    switch state.stage {
    | Pending(p) => {
        ...state,
        stage: Pending({...p, requestedAt: reissuedAt, challenge: None, proofHash: None}),
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
  // The account was erased: the address is nobody's, and nobody was told of an
  // attempt on it.
  | RegistrationReleased(_) => {...state, stage: Unclaimed, lastNoticeAt: None}
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

/** Whether the app declares `role` as one a person is invited to. */
let isByInvitation = (table, role) =>
  switch table->Reventless.Admission.strategyOf(role) {
  | Invitation(_) => true
  | SelfService | Provisioned => false
  }

/** A pending registration nobody finished stops holding the address. Measured
    from its challenge when one went out, else from the claim or the last reissue. */
let hasLapsed = (p: pending, ~now) =>
  switch p.challenge {
  | Some(c) => Guards.hasExpired(c, ~now, ~policy=policyOf(p))
  | None => Guards.elapsedSeconds(~from=p.requestedAt, ~to_=now) >= policyOf(p).tokenTtl
  }

let refusalReason = (r: Guards.refusal) =>
  switch r {
  | AddressSuperseded => "AddressSuperseded"
  | ChallengeExpired => "ChallengeExpired"
  | AlreadySettled => "AlreadySettled"
  | AttemptsExhausted => "AttemptsExhausted"
  | ProofMismatch => "ProofMismatch"
  }

/** The decision over the app's table, which says which roles are self-service
    and which are by invitation. */
module Make = (App: Reventless.Admission.Declaration) => {
  module Spec = Spec
  let moduleUrl = moduleUrl

  type state = state
  let initialState = initialState
  let evolve = evolve

  let decide = (state, command) =>
    switch command {
    // 🚨 Every arm a visitor reaches answers `Ok`, and the order is the security
    // decision: the policy is consulted before the address, so a closed
    // deployment sends nothing — not even the notice to an address that is
    // already registered.
    | Register({emailId, email, role, requestedAt, ?language}) =>
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
          | _ =>
            Ok([
              RegistrationAttemptedOnTakenAddress({
                emailId,
                email: Value(email),
                attemptedAt: requestedAt,
              }),
            ])
          }
        | Verified => Ok([])
        // A visitor cannot take over a claim, an inviter's included, while it holds.
        | Pending(p) if !hasLapsed(p, ~now=requestedAt) => Ok([])
        | Pending(_) =>
          Ok([
            RegistrationExpired({emailId: emailId}),
            RegistrationRequested({emailId, email: Value(email), roles, requestedAt, ?language}),
          ])
        | Unclaimed =>
          Ok([RegistrationRequested({emailId, email: Value(email), roles, requestedAt, ?language})])
        }
      }

    // The policy is not consulted: it says whether visitors may sign themselves
    // up, and an invitation is not that. The table is, because it is the hard
    // cap on how each role is admitted.
    | Invite({emailId, email, roles, invitedBy, requestedAt, ?language}) =>
      switch roles->Array.find(r => !isByInvitation(App.table, r)) {
      | Some(role) => Error(NotByInvitation({role: (role :> string)}))
      | None if roles == [] => Error(NoRoleToGrant)
      | None =>
        let invited = RegistrationInvited({
          emailId,
          email: Value(email),
          roles: roles->Array.map(r => (r :> string)),
          invitedBy,
          invitedAt: requestedAt,
          ?language,
        })
        switch state.stage {
        // An address that holds an account, or is about to, is not registered
        // twice; granting it roles is not registration.
        | Completed | Verified => Ok([])
        | Pending(p) if !hasLapsed(p, ~now=requestedAt) => Ok([])
        | Pending(_) => Ok([RegistrationExpired({emailId: emailId}), invited])
        | Unclaimed => Ok([invited])
        }
      }

    | IssueRegistrationChallenge({emailId, proofHash, issuedAt, ?language, ?messageKey}) =>
      switch state.stage {
      | Pending(p) =>
        switch Guards.onIssueRequested(
          ~contact=contactOf(emailId),
          ~existing=p.challenge,
          ~now=issuedAt,
          ~policy=policyOf(p),
        ) {
        | Issue =>
          Ok([RegistrationChallengeIssued({emailId, proofHash, issuedAt, ?language, ?messageKey})])
        // A redelivered request mints nothing, and because nothing is emitted,
        // sends nothing either.
        | AlreadyOpen => Ok([])
        }
      | _ => Ok([])
      }

    // Only a code that went out can be voided — one still on its way would be
    // replaced by a second in flight, and the first to arrive would be the one
    // recorded. And not twice within the resend cooldown, so a door that
    // reaches this cannot be used to flood an inbox.
    | ReissueRegistrationChallenge({emailId, requestedAt}) =>
      switch state.stage {
      | Pending({challenge: Some(c)} as p)
        if Guards.elapsedSeconds(~from=c.issuedAt, ~to_=requestedAt) >=
        policyOf(p).resendCooldown =>
        Ok([
          RegistrationChallengeReissued({
            emailId,
            email: p.email,
            reissuedAt: requestedAt,
            invitedBy: ?p.invitedBy,
            language: ?p.language,
          }),
        ])
      | _ => Ok([])
      }

    | SubmitRegistrationProof({emailId, proofHash, presentedAt}) =>
      switch state.stage {
      | Pending({challenge: Some(c), proofHash: Some(held), roles} as p) =>
        switch Guards.onProofPresented(
          c,
          ~hostContact=None,
          ~proofMatches=proofHash == held,
          ~now=presentedAt,
          ~policy=policyOf(p),
        ) {
        | Settle => Ok([RegistrationProofAccepted({emailId, email: p.email, roles, proofHash})])
        | Refuse(reason) => Ok([RegistrationProofRefused({emailId, reason: refusalReason(reason)})])
        }
      // No challenge to answer: nothing to count it against, and nothing to say.
      | _ => Ok([])
      }

    // Only a claim nobody has proved: once a proof settled, an account is on
    // its way, and withdrawing the claim would not stop it.
    | WithdrawRegistration({emailId, withdrawnAt}) =>
      switch state.stage {
      | Pending(_) => Ok([RegistrationWithdrawn({emailId, withdrawnAt})])
      | Unclaimed | Verified | Completed => Ok([])
      }

    // Only an account: a claim nobody proved is withdrawn, and one being turned
    // into an account is released once the account exists and is erased.
    | ReleaseRegistration({emailId, releasedAt}) =>
      switch state.stage {
      | Completed => Ok([RegistrationReleased({emailId, releasedAt})])
      | Unclaimed | Pending(_) | Verified => Ok([])
      }

    | RecordRegistrationCompleted({emailId}) =>
      switch state.stage {
      | Verified => Ok([RegistrationCompleted({emailId: emailId})])
      | _ => Ok([])
      }
    }
}
