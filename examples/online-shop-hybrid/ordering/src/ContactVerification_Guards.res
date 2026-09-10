/**
The graft's decision rules, compiled once and called by every host: a proof for
an address the entity has moved off settles nothing, a settled challenge settles
once, and expiry is decided when the proof arrives rather than on a timer.

The host keeps its own state and builds a `verification` per call from fields it
already holds. The challenge is *not* host state — an aggregate is snapshotted,
and a secret in a snapshot is a secret in every backup of one.
*/
/** The two fields the rules read, as the host holds them. Its invariant, which
    every host arm must preserve: `verifiedAddress` is `None` or equal to
    `contact`. */
type verification = {
  contact: ContactVerification.contact,
  verifiedAddress: option<ContactVerification.contact>,
}

/** One challenge, as the trait's own ledger holds it. The secret itself is never
    here — only whether a presented one matched, which the caller decides. */
type challenge = {
  contact: ContactVerification.contact,
  purpose: ContactVerification.purpose,
  issuedAt: Reventless.DateTime.t,
  attempts: int,
  settled: bool,
}

/** What the host still owes a proof for, or `None` — the stand-down. A host
    whose current address is already the verified one spends no capability call,
    the same arm as a map picker having already supplied the point. */
let contactToVerify = (v: verification): option<ContactVerification.contact> =>
  v.verifiedAddress == Some(v.contact) ? None : Some(v.contact)

let elapsedSeconds = (~from: Reventless.DateTime.t, ~to_: Reventless.DateTime.t): int =>
  Int.fromFloat((Reventless.DateTime.millis(to_) -. Reventless.DateTime.millis(from)) /. 1000.)

/** Expiry is decided when the proof arrives, not by a scheduled fire. No
    process-manager state to keep, and testable without controlling a clock. */
let hasExpired = (c: challenge, ~now, ~policy: ContactVerification.policy): bool =>
  elapsedSeconds(~from=c.issuedAt, ~to_=now) >= policy.tokenTtl

/** Why a presented proof settles nothing. Named rather than one blank refusal,
    because the host tells the subject which of these happened and tells an
    anonymous caller nothing — that distinction is about who is asking, not about
    whether the reason is known here. */
type refusal =
  /** 🚨 The security control. The host's address changed while this challenge
      was open, so the proof names an address its presenter may no longer hold.
      Settling it would be "change the address, then present the old one's link",
      which is an account takeover. */
  | AddressSuperseded
  | ChallengeExpired
  | AlreadySettled
  | AttemptsExhausted
  | ProofMismatch

type proofVerdict =
  | Settle
  | Refuse(refusal)

/**
The order of these checks is a security decision, not a style one.

Supersession is tested before anything else, so a stale challenge is refused on
the fact that makes it dangerous rather than on whichever of its other
properties happened to lapse first — a superseded challenge that had also
expired must not be reported as merely expired. The proof itself is compared
last, so none of the structural refusals depend on the secret.

`hostContact` is an option because the two flows this competency serves differ
in whether there *is* a host. Changing an address has one, and supersession is
checkable. Registering has none — the subject the address will belong to does
not exist yet — so `None` means "nothing to be superseded by", not "skip the
check". A ledger that simply does not track the host also passes `None`, and
relies on the host's own write-back guard, which is why that one is not
optional.
*/
let onProofPresented = (
  c: challenge,
  ~hostContact: option<ContactVerification.contact>,
  ~proofMatches: bool,
  ~now: Reventless.DateTime.t,
  ~policy: ContactVerification.policy,
): proofVerdict =>
  if hostContact->Option.mapOr(false, held => c.contact != held) {
    Refuse(AddressSuperseded)
  } else if c.settled {
    Refuse(AlreadySettled)
  } else if hasExpired(c, ~now, ~policy) {
    Refuse(ChallengeExpired)
  } else if c.attempts >= policy.maxAttempts {
    Refuse(AttemptsExhausted)
  } else if !proofMatches {
    Refuse(ProofMismatch)
  } else {
    Settle
  }

type verdict = Append | Ignore

/**
The write-back rule, applied where the host records the outcome.

Two guards, and the first is the same security control `onProofPresented`
applies to the challenge — deliberately duplicated rather than trusted once. The
ledger refusing to settle and the host refusing to record are different
failures: a verdict can reach the host by redelivery, by a replayed command, or
from a ledger that is simply wrong, and only this one is inside the host's own
consistency boundary. The second is the ordinary redelivery no-op.
*/
let onVerifiedReport = (v: verification, ~contact: ContactVerification.contact): verdict =>
  if contact != v.contact {
    Ignore
  } else if v.verifiedAddress == Some(contact) {
    Ignore
  } else {
    Append
  }

type issuance =
  /** Mint a secret and send it. */
  | Issue
  /** An open challenge already covers this address, so a redelivered request
      mints nothing and sends nothing. Commands arrive at least once, and a slice
      re-publishes until its work clears. */
  | AlreadyOpen

/**
Whether a request to challenge an address produces a new secret.

Decided against the ledger's own state and nothing else. The stand-down —
whether an address is owed a proof at all — is `contactToVerify`, and it belongs
to whoever reads the host, because a ledger has no host to read. Folding the two
together read naturally with one host in view and stopped compiling the moment a
second flow had none.
*/
let onIssueRequested = (
  ~contact: ContactVerification.contact,
  ~existing: option<challenge>,
  ~now: Reventless.DateTime.t,
  ~policy: ContactVerification.policy,
): issuance =>
  switch existing {
  | Some(c) if c.contact == contact && !c.settled && !hasExpired(c, ~now, ~policy) => AlreadyOpen
  | _ => Issue
  }

type resend =
  | Send
  /** Asked for again too soon, carrying what is left of the cooldown so the host
      can say when rather than only no. */
  | TooSoon(Reventless.Duration.t)
  /** Nothing open to send again. */
  | NothingOpen

/**
A deliberate "send it again". The same secret goes out rather than a fresh one,
so a link already sitting in a mailbox keeps working — minting a new one would
invalidate the message the person is looking at while they read it.
*/
let onResendRequested = (
  ~contact: ContactVerification.contact,
  ~existing: option<challenge>,
  ~now: Reventless.DateTime.t,
  ~policy: ContactVerification.policy,
): resend =>
  switch existing {
  | None => NothingOpen
  | Some(c) =>
    if c.contact != contact || c.settled || hasExpired(c, ~now, ~policy) {
      NothingOpen
    } else {
      let waited = elapsedSeconds(~from=c.issuedAt, ~to_=now)
      waited >= policy.resendCooldown ? Send : TooSoon(policy.resendCooldown - waited)
    }
  }
